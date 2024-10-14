local redis = require "resty.redis"
local resty_lock = require "resty.lock"

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
        return nil, "Failed to connect to Redis: " .. err
    end

    return red
end

-- Function to get token from URL parameter
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Function to fetch batch quota from Redis
local function fetch_batch_quota(red, redis_key)
    local current_time = ngx.now()
    local window_start = current_time - window_size

    -- Start a Redis transaction
    local ok, err = red:multi()
    if not ok then
        return nil, "Failed to start Redis transaction: " .. err
    end

    -- Queue commands in the transaction
    red:zremrangebyscore(redis_key, 0, window_start)
    red:zcard(redis_key)

    -- Execute the transaction
    local results, err = red:exec()
    if not results then
        return nil, "Failed to execute Redis transaction: " .. err
    end

    -- Parse the results
    local removed = results[1]
    local count = results[2]

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
local function update_redis_with_exhausted_batch(red, shared_dict, redis_key)
    local multi_result, err = red:multi()
    if not multi_result then
        return false, "Failed to start Redis transaction: " .. err
    end

    local timestamps_len = shared_dict:llen(redis_key .. ":timestamps")
    for i = 1, timestamps_len do
        local ts, err = shared_dict:lpop(redis_key .. ":timestamps")
        if ts then
            red:zadd(redis_key, ts, ts)
        else
            red:discard()
            return false, "Failed to pop timestamp from shared dict: " .. err
        end
    end

    local exec_result, err = red:exec()
    if not exec_result then
        return false, "Failed to execute Redis transaction: " .. err
    end

    return true
end

-- Function to handle batch quota and timestamps
local function process_batch_quota(shared_dict, redis_key, red)
    local batch_quota = shared_dict:get(redis_key .. ":batch")
    local timestamps_len = shared_dict:llen(redis_key .. ":timestamps")

    if not batch_quota or batch_quota == 0 or not timestamps_len then
        -- Update Redis with the previously exhausted batch if it exists
        if timestamps_len and timestamps_len > 0 then
            local success, err = update_redis_with_exhausted_batch(red, shared_dict, redis_key)
            if not success then
                return nil, err
            end
        end

        -- Fetch new batch quota
        batch_quota, ttl = fetch_batch_quota(red, redis_key)
        if batch_quota == nil then
            return nil, ttl  -- ttl contains error message in this case
        end

        if batch_quota > 0 then
            -- Store new batch quota in shared memory
            local ok, err = shared_dict:set(redis_key .. ":batch", batch_quota, ttl)
            if not ok then
                return nil, "Failed to set batch quota in shared memory: " .. err
            end
            -- Reset the timestamps for the new batch (list will be empty)
            ok, err = shared_dict:delete(redis_key .. ":timestamps")
            if not ok then
                return nil, "Failed to reset timestamps in shared memory: " .. err
            end
        end
    end

    return batch_quota, timestamps_len
end

-- Function to process the request. Increment the used count and check if request is allowed
local function increment_and_check(shared_dict, redis_key, red, batch_quota, timestamps_len)
    local allowed = false
    if batch_quota > 0 then
        -- Add current timestamp to the batch
        local current_time = ngx.now()
        local length, err = shared_dict:rpush(redis_key .. ":timestamps", current_time)
        if not length then
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
            local success, err = update_redis_with_exhausted_batch(red, shared_dict, redis_key)
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
                    ok, err = shared_dict:rpush(redis_key .. ":timestamps", current_time)
                    if not ok then
                        return nil, "Failed to reset timestamps in shared memory: " .. err
                    end
                    allowed = true
                end
            else
                return nil, err
            end
        end
    end

    return allowed
end

-- Main function
local function main()
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local redis_key = "rate_limit:" .. token

    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(redis_key)
    if not elapsed then
        ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local batch_quota, timestamps_len = process_batch_quota(shared_dict, redis_key, red)
    if not batch_quota then
        ngx.log(ngx.ERR, "Failed to handle batch quota: ", timestamps_len)  -- timestamps_len contains error message in this case
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local allowed, err = increment_and_check(shared_dict, redis_key, red, batch_quota, timestamps_len)
    if err then
        ngx.log(ngx.ERR, "Failed to process request: ", err)
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local ok, err = lock:unlock()
    if not ok then
        ngx.log(ngx.ERR, "Failed to release lock: ", err)
    end

    if not allowed then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
end

-- Execute main function
main()