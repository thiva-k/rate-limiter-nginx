local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Token bucket parameters
local bucket_capacity = 5 -- Maximum tokens in the bucket
local refill_rate = 5 / 3 -- Tokens generated per second
local requested_tokens = 1 -- Number of tokens required per request

-- Lock settings
local lock_timeout = 1000 -- Lock timeout in milliseconds
local max_retries = 100 -- Maximum number of retries to acquire the lock
local retry_delay = 100 -- Delay between retries in milliseconds

-- Helper function to initialize Redis connection
local function init_redis()
    local red, err = redis:new()
    if not red then
        return nil, err
    end

    red:set_timeout(redis_timeout)

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

-- Helper function to get URL token
local function get_request_token()
    local token = ngx.var.arg_token

    if not token then
        return nil, "Token not provided"
    end

    return token
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

-- Main rate limiting logic
local function check_rate_limit(red, token)
    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    local results, err = red:mget(tokens_key, last_access_key)
    if not results then
        return nil, "Failed to execute Redis MGET: " .. err
    end

    local now = ngx.now() * 1000 -- Current timestamp in milliseconds
    local last_token_count = tonumber(results[1]) or (bucket_capacity * 1000)
    local last_access_time = tonumber(results[2]) or now

    -- Calculate the number of tokens to be added due to the elapsed time since the last access
    local elapsed_time_ms = math.max(0, now - last_access_time)
    local tokens_to_add = elapsed_time_ms * refill_rate
    local new_token_count = math.floor(math.min(bucket_capacity * 1000, last_token_count + tokens_to_add))

    -- Calculate TTL for the Redis keys
    local ttl = math.floor(bucket_capacity / refill_rate * 2)

    -- Check if there are enough tokens for the request
    if new_token_count >= (requested_tokens * 1000) then
        -- Deduct tokens and update Redis state
        new_token_count = new_token_count - (requested_tokens * 1000)

        red:init_pipeline()
        red:set(tokens_key, new_token_count, "EX", ttl)
        red:set(last_access_key, now, "EX", ttl)
        local results, err = red:commit_pipeline()
        if not results then
            return nil, "Failed to execute Redis pipeline: " .. err
        end

        return true, "allowed"
    else
        -- Not enough tokens, rate limit the request
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

    local pcall_status, check_rate_limit_result, message = pcall(check_rate_limit, red, token)

    if not release_lock(red, token, lock_value) then
        ngx.log(ngx.ERR, "Failed to release lock")
    end

    local ok, err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", err)
    end

    if not pcall_status then
        ngx.log(ngx.ERR, check_rate_limit_result)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if not check_rate_limit_result then
        ngx.log(ngx.ERR, "Failed to rate limit: ", message)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if message == "rejected" then
        ngx.log(ngx.INFO, "Rate limit exceeded for token: ", token)
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
end

main()
