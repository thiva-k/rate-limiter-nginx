local redis = require "resty.redis"
local resty_lock = require "resty.lock"
local cjson = require "cjson"

-- Global variables
local redis_host = "redis"
local redis_port = 6379
local rate_limit = 500 -- 500 requests per minute
local window_size = 60 -- 60 second window
local batch_percent = 0.1 -- 10% of remaining quota
local min_batch_size = 1 -- Minimum batch size to use batching

-- Function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
        return nil, err
    end

    return red
end

-- Function to get token from URL parameter
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        return nil, "Token not provided"
    end
    return token
end

-- Function to fetch batch quota from Redis
local function fetch_batch_quota(red, redis_key)
    local current_time = ngx.now()
    local window_start = current_time - window_size

    -- Remove old entries and count current entries
    local removed, err = red:zremrangebyscore(redis_key, 0, window_start)
    if err then
        ngx.log(ngx.ERR, "Failed to remove old entries: ", err)
        return nil, nil
    end

    local count, err = red:zcard(redis_key)
    if err then
        ngx.log(ngx.ERR, "Failed to count entries: ", err)
        return nil, nil
    end

    -- Calculate remaining quota and batch size
    local remaining = math.max(0, rate_limit - count)
    if remaining == 0 then
        return 0, window_size  -- No more requests allowed in this window
    end

    local batch_size = math.floor(remaining * batch_percent)
    batch_size = math.max(math.min(batch_size, remaining), min_batch_size)

    return batch_size, window_size
end

-- Function to update Redis with the exhausted batch
local function update_redis_with_exhausted_batch(red, redis_key, timestamps)
    local multi_result, err = red:multi()
    if not multi_result then
        ngx.log(ngx.ERR, "Failed to start Redis transaction: ", err)
        return false
    end

    for _, ts in ipairs(timestamps) do
        local ok, err = red:zadd(redis_key, ts, ts)
        if not ok then
            ngx.log(ngx.ERR, "Failed to add timestamp to Redis: ", err)
            red:discard()
            return false
        end
    end

    local exec_result, err = red:exec()
    if not exec_result then
        ngx.log(ngx.ERR, "Failed to execute Redis transaction: ", err)
        return false
    end

    return true
end

-- Function to handle batch quota and timestamps
local function handle_batch_quota(shared_dict, redis_key, red)
    local batch_quota, err = shared_dict:get(redis_key .. ":batch")
    local timestamps_json, err_ts = shared_dict:get(redis_key .. ":timestamps")
    local timestamps = timestamps_json and cjson.decode(timestamps_json) or {}

    if not batch_quota or batch_quota == 0 or not timestamps_json then
        -- Update Redis with the previously exhausted batch if it exists
        if #timestamps > 0 then
            local success = update_redis_with_exhausted_batch(red, redis_key, timestamps)
            if not success then
                return nil, "Failed to update Redis with exhausted batch"
            end
        end

        -- Fetch new batch quota
        batch_quota, ttl = fetch_batch_quota(red, redis_key)
        if batch_quota == nil then
            return nil, "Failed to fetch batch quota"
        end

        if batch_quota > 0 then
            -- Store new batch quota in shared memory
            local ok, err = shared_dict:set(redis_key .. ":batch", batch_quota, ttl)
            if not ok then
                return nil, "Failed to set batch quota in shared memory: " .. err
            end
            -- Reset the timestamps for the new batch
            ok, err = shared_dict:set(redis_key .. ":timestamps", cjson.encode({}), ttl)
            if not ok then
                return nil, "Failed to reset timestamps in shared memory: " .. err
            end
            timestamps = {}
        end
    end

    return batch_quota, timestamps
end

-- Function to process the request
local function process_request(shared_dict, redis_key, red, batch_quota, timestamps)
    local allowed = false
    if batch_quota > 0 then
        -- Add current timestamp to the batch
        local current_time = ngx.now()
        table.insert(timestamps, current_time)
        
        -- Update timestamps in shared memory
        local ok, err = shared_dict:set(redis_key .. ":timestamps", cjson.encode(timestamps))
        if not ok then
            return nil, "Failed to update timestamps in shared memory: " .. err
        end
        
        -- Decrement the batch quota
        local new_quota, err = shared_dict:incr(redis_key .. ":batch", -1, 0)
        if err then
            return nil, "Failed to decrement batch quota: " .. err
        end
        
        if new_quota >= 0 then
            allowed = true
        else
            -- Batch is exhausted, update Redis and fetch a new batch
            local success = update_redis_with_exhausted_batch(red, redis_key, timestamps)
            if success then
                -- Fetch new batch quota
                batch_quota, ttl = fetch_batch_quota(red, redis_key)
                if batch_quota and batch_quota > 0 then
                    -- Store new batch quota in shared memory
                    ok, err = shared_dict:set(redis_key .. ":batch", batch_quota - 1, ttl)
                    if not ok then
                        return nil, "Failed to set new batch quota in shared memory: " .. err
                    end
                    -- Reset the timestamps for the new batch, including the current request
                    ok, err = shared_dict:set(redis_key .. ":timestamps", cjson.encode({current_time}), ttl)
                    if not ok then
                        return nil, "Failed to reset timestamps in shared memory: " .. err
                    end
                    allowed = true
                end
            end
        end
    end

    return allowed
end

-- Main function
local function main()
    local red, err = init_redis()
    if not red then
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local token, err = get_token()
    if not token then
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local redis_key = "rate_limit:" .. token

    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(redis_key, { timeout = 10 })
    if not elapsed then
        ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local batch_quota, timestamps = handle_batch_quota(shared_dict, redis_key, red)
    if not batch_quota then
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local allowed, err = process_request(shared_dict, redis_key, red, batch_quota, timestamps)
    if err then
        ngx.log(ngx.ERR, err)
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    lock:unlock()

    if not allowed then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
end

-- Execute main function
main()