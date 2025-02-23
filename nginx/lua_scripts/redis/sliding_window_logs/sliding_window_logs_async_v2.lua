local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local rate_limit = 10 -- 500 requests per minute
local window_size = 60 -- 60 second window
local batch_percent = 0.5 -- 10% of remaining quota
local min_batch_size = 1 -- Minimum batch size to use batching

-- Lua script to fetch batch quota
local lua_script = [[
    local key = KEYS[1]
    local window_start = tonumber(ARGV[1])
    local rate_limit = tonumber(ARGV[2])

    -- Remove expired entries
    redis.call("ZREMRANGEBYSCORE", key, 0, window_start)

    -- Get the count of remaining members
    local count = redis.call("ZCARD", key)

    return count
]]

local script_sha -- Cache the script SHA

-- Helper function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, "Failed to connect to Redis: " .. err
    end
    return red
end

-- Helper function to close Redis connection
local function close_redis(red)
    local ok, err = red:set_keepalive(max_idle_timeout, pool_size)
    if not ok then
        return nil, err
    end
    return true
end

-- Helper function to get URL token
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Function to fetch batch quota from Redis
local function fetch_batch_quota(red, redis_key)
    local current_time = ngx.now() * 1000
    local window_start = current_time - window_size

    -- Cache the script SHA if not already cached
    if not script_sha then
        local sha, err = red:script("load", lua_script)
        if not sha then
            return nil, "Failed to load Lua script into Redis: " .. err
        end
        script_sha = sha
    end

    -- Execute the Lua script
    local res, err = red:evalsha(script_sha, 1, redis_key, window_start, rate_limit)
    if not res then
        return nil, "Failed to execute Redis Lua script: " .. err
    end
    -- TODO: use local
    count = tonumber(res)

    local remaining = math.max(0, rate_limit - count)
    if remaining == 0 then
        return 0, window_size -- No more requests allowed in this window     -- TODO: window_size is global
    end

    local batch_size = math.ceil(remaining * batch_percent)

    return batch_size, window_size
end

-- Function to update Redis with the exhausted batch
local function update_redis_with_exhausted_batch(red, shared_dict, redis_key)
    -- Prepare batch ZADD arguments
    local zadd_args = {}
    local list_key = redis_key .. ":timestamps"
    local timestamps_len = shared_dict:llen(list_key)

    for i = 1, timestamps_len do
        local ts, err = shared_dict:lpop(list_key)
        if ts then
            -- Add the timestamp twice: once as score and once as member
            table.insert(zadd_args, ts)
            table.insert(zadd_args, ts)
        else
            return false, "Failed to pop timestamp from shared dict: " .. (err or "unknown error")
        end
    end

    -- Only execute ZADD if there are timestamps to process
    if #zadd_args > 0 then
        local ok, err = red:zadd(redis_key, unpack(zadd_args))
        if not ok then
            return false, "Failed to update Redis with exhausted batch: " .. err
        end
    end

    return true
end

-- Function to handle batch quota and timestamps
local function process_batch_quota(shared_dict, redis_key, red)
    local batch_quota = shared_dict:get(redis_key .. ":batch")
    local timestamps_len = shared_dict:llen(redis_key .. ":timestamps") -- TODO: If key does not exist, it is interpreted as an empty list and 0 is returned. When the key already takes a value that is not a list, it will return nil and "value not a list"

    if not batch_quota or batch_quota == 0 or not timestamps_len then

        -- Fetch new batch quota
        local new_quota, ttl = fetch_batch_quota(red, redis_key)
        if new_quota == nil then
            return nil, ttl -- ttl contains error message in this case
        end

        if new_quota > 0 then
            -- Store new batch quota in shared memory
            local ok, err = shared_dict:set(redis_key .. ":batch", new_quota, ttl)
            if not ok then
                return nil, "Failed to set batch quota in shared memory: " .. err
            end
            batch_quota = new_quota
        else
            batch_quota = 0
        end
    end

    return batch_quota, timestamps_len
end

-- Function to process the request
local function increment_and_check(shared_dict, redis_key, red, batch_quota, timestamps_len) -- TODO: timestamps_len unused
    if batch_quota <= 0 then
        return false
    end

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

    if new_quota == 0 then
        -- Update Redis with the exhausted batch --TODO: no need to check length is true also better to move this logic to ratelimit
        if length and length > 0 then
            local success, err = update_redis_with_exhausted_batch(red, shared_dict, redis_key)
            if not success then
                return nil, err
            end
        end
    end

    return true

end

-- Main rate limiting logic
local function check_rate_limit(red, token, shared_dict)
    local redis_key = "rate_limit:" .. token

    -- TODO: put it oustide
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(redis_key)
    if not elapsed then
        return nil, "Failed to acquire lock: " .. err
    end

    -- Ensure lock is always released
    local function cleanup(err)
        local ok, unlock_err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "Failed to release lock: ", unlock_err)
        end
        if err then
            return nil, err
        end
        return true
    end

    -- TODO: timestamps_len is unecessary
    local batch_quota, timestamps_len = process_batch_quota(shared_dict, redis_key, red)
    if not batch_quota then
        return cleanup("Failed to handle batch quota: " .. timestamps_len)
    end

    local allowed, err = increment_and_check(shared_dict, redis_key, red, batch_quota, timestamps_len)
    if err then
        return cleanup("Failed to process request: " .. err)
    end

    if not allowed then
        cleanup()
        return ngx.HTTP_TOO_MANY_REQUESTS
    end

    cleanup()
    return ngx.HTTP_OK
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    -- Get token from URL parameters
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Initialize Redis connection
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- TODO: let's create common helper fuction for this
    -- Get shared dictionary
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Run rate limiting check with error handling
    local res, status = pcall(check_rate_limit, red, token, shared_dict)

    -- Properly close Redis connection
    local ok, close_err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", close_err)
    end

    -- Handle any errors from the rate limiting check
    if not res then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif status == ngx.HTTP_TOO_MANY_REQUESTS then
        ngx.exit(status)
    end
end

-- Run the main function
main()
