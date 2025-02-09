local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Leaky bucket parameters
local max_delay = 3000 -- 3 second,
local leak_rate = 1 -- Requests leaked per second

-- Lock settings
local lock_timeout = 1000 -- Lock timeout in milliseconds
local max_retries = 100 -- Maximum number of retries to acquire the lock
local retry_delay = 10 -- Delay between retries in milliseconds

-- Helper function to initialize Re dis connection
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

    for i = 1, max_retries do
        local lock_value = ngx.now() * 1000 -- Current timestamp as lock value
        local res, err = red:set(lock_key, lock_value, "NX", "PX", lock_timeout)
        if res == "OK" then
            return true, lock_value
        elseif err then
            return false
        end

        -- Delay before retrying
        local delay = (retry_delay / 1000) -- Convert milliseconds to seconds
        ngx.sleep(delay)
    end

    return false -- Failed to acquire lock after max retries
end

-- Function to release a lock
local function release_lock(red, token, lock_value)
    local lock_key = "rate_limit_lock:" .. token

    local script = [[
        if redis.call("get", KEYS[1]) == ARGV[1] then
            return redis.call("del", KEYS[1])
        else
            return 0
        end
    ]]

    local res, err = red:eval(script, 1, lock_key, lock_value)
    if not res then
        return nil, err
    end

    return true
end

-- Helper function to get URL token
local function get_request_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end

    return token
end

-- Main rate limiting logic
local function rate_limit(red, token)
    -- Redis key for the sorted set queue
    local queue_key = "rate_limit:" .. token .. ":queue"

    -- Calculate bucket capacity based on max delay and leak rate
    local bucket_capacity = math.floor(max_delay / 1000 * leak_rate)

    -- Current timestamp in milliseconds
    local now = ngx.now() * 1000

    -- Get the head of the queue to check the last leak time, remove old entries and get the current queue length
    red:multi()
    red:zrevrange(queue_key, 0, 0, "WITHSCORES")
    red:zremrangebyscore(queue_key, 0, now)
    red:zcard(queue_key)
    local results, err = red:exec()
    if not results then
        return nil, "Failed to execute Redis transaction: " .. err
    end

    local last_leak_time = now
    if #results[1] > 0 then
        last_leak_time = tonumber(results[1][2])
    end

    local queue_length = tonumber(results[3]) or 0

    if queue_length + 1 <= bucket_capacity then
        local default_delay = math.floor(1 / leak_rate * 1000)

        local delay = 0
        local time_diff = now - last_leak_time
        if time_diff ~= 0 then
            delay = math.max(0, default_delay - time_diff)
        end

        local leak_time = now + delay
        local ttl = math.floor(bucket_capacity / leak_rate * 2)

        red:multi()
        red:zadd(queue_key, leak_time, leak_time)
        red:expire(queue_key, ttl)
        local results, err = red:exec()
        if not results then
            return nil, "Failed to execute Redis transaction: " .. err
        end

        -- Convert delay to seconds
        delay = math.floor(delay) / 1000

        return true, "allowed", delay
    else
        return true, "rejected"
    end
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    local token, err = get_request_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local ok, lock_value = acquire_lock(red, token)
    if not ok then
        ngx.log(ngx.ERR, "Failed to acquire lock")
        close_redis(red)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local pcall_status, rate_limit_result, message, delay = pcall(rate_limit, red, token)

    if not release_lock(red, token, lock_value) then
        ngx.log(ngx.ERR, "Failed to release lock")
    end

    local ok, err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", err)
    end

    if not pcall_status then
        ngx.log(ngx.ERR, rate_limit_result)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if not rate_limit_result then
        ngx.log(ngx.ERR, "Failed to rate limit: ", message)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if message == "rejected" then
        ngx.log(ngx.INFO, "Rate limit exceeded for token: ", token)
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    else
        ngx.sleep(delay)
        ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
    end
end

-- Run the main function
main()
