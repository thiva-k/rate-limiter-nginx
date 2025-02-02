local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout

-- Leaky bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local leak_rate = 1 -- Tokens leaked per second
local requested_tokens = 1 -- Number of tokens required per request

-- Lock settings
local lock_timeout = 1000 -- Lock timeout in milliseconds
local max_retries = 100 -- Maximum number of retries to acquire the lock
local retry_delay = 100 -- Delay between retries in milliseconds
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Helper function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, err
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

-- Function to acquire a lock with retries
local function acquire_lock(red, token)
    -- Unique lock key for each user
    local lock_key = "rate_limit_lock:" .. token
    local lock_value = ngx.now() * 1000 -- Current timestamp as lock value

    for i = 1, max_retries do
        local res, err = red:set(lock_key, lock_value, "NX", "PX", lock_timeout)
        if res == "OK" then
            return true
        elseif err then
            return false
        end
        -- Delay before retrying
        ngx.sleep(retry_delay / 1000) -- Convert milliseconds to seconds
    end

    return false -- Failed to acquire lock after max retries
end

-- Function to release a lock
local function release_lock(red, token)
    local lock_key = "rate_limit_lock:" .. token

    local res, err = red:del(lock_key)
    if not res then
        return false
    end

    return true
end

-- Helper function to get URL token
local function get_user_url_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end

    return token
end

-- Main rate limiting logic
local function rate_limit(red, token)
    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    local results, err = red:mget(tokens_key, last_access_key)
    if not results then
        ngx.log(ngx.ERR, "Failed to execute Redis MGET: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    local now = ngx.now() * 1000 -- Current timestamp in milliseconds
    local last_tokens = tonumber(results[1]) or 0
    local last_access = tonumber(results[2]) or now

    -- Calculate the number of tokens that have leaked due to the elapsed time since the last leak
    local elapsed = math.max(0, now - last_access)
    local leaked_tokens = math.floor(elapsed * leak_rate / 1000)
    local bucket_level = math.max(0, last_tokens - leaked_tokens)

    -- Verify if the current token level is below the bucket capacity.
    if bucket_level + requested_tokens <= bucket_capacity then
        -- Calculate the delay between requests based on the leak rate in milliseconds
        local delay_between_requests = 1 / leak_rate * 1000

        -- Assumption: Atleast 1ms delay will be there between request processing
        -- If time difference either 0 or greater than delay_between_requests then no need to add delay
        local time_diff = now - last_access
        local delay = 0
        if time_diff < 0 or (time_diff > 0 and time_diff < delay_between_requests) then
            delay = -time_diff + delay_between_requests
        end

        -- For the first request no need to increment the bucket level as we allow it immediately
        if (delay ~= 0) or (bucket_level ~= 0) then
            bucket_level = bucket_level + requested_tokens
        end

        -- Calculate TTL for the Redis keys
        local ttl = math.floor(bucket_capacity / leak_rate * 2)

        red:init_pipeline()
        red:set(tokens_key, bucket_level, "EX", ttl)
        red:set(last_access_key, now + delay, "EX", ttl)
        local results, err = red:commit_pipeline()
        if not results then
            ngx.log(ngx.ERR, "Failed to execute Redis pipeline: ", err)
            return ngx.HTTP_INTERNAL_SERVER_ERROR
        end

        ngx.sleep(delay / 1000)

        ngx.say("Request allowed")
        return ngx.HTTP_OK
    else
        -- Not enough tokens, rate limit the request
        return ngx.HTTP_TOO_MANY_REQUESTS
    end
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    local token, err = get_user_url_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Try to acquire the lock with retries
    if not acquire_lock(red, token) then
        ngx.log(ngx.ERR, "Failed to acquire lock")
        close_redis(red)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local res, status = pcall(rate_limit, red, token)

    if not release_lock(red, token) then
        ngx.log(ngx.ERR, "Failed to release lock")
    end

    local ok, err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", err)
    end

    if not res then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    else
        ngx.exit(status)
    end
end

-- Run the main function
main()
