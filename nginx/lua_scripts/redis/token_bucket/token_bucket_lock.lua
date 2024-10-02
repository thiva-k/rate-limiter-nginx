local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout

-- Token bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local refill_rate = 1 -- Tokens generated per second
local requested_tokens = 1 -- Number of tokens required per request

-- Lock settings
local lock_timeout = 1000 -- Lock timeout in milliseconds
local max_retries = 100 -- Maximum number of retries to acquire the lock
local retry_delay = 100 -- Delay between retries in milliseconds

-- Helper function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR) -- 500
    end
    return red
end

-- Helper function to get URL token
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        ngx.exit(ngx.HTTP_BAD_REQUEST) -- 400
    end
    return token
end

-- Function to acquire a lock with retries
local function acquire_lock(red, lock_key)
    local lock_value = ngx.now() * 1000 -- Current timestamp as lock value
    for i = 1, max_retries do
        local res, err = red:set(lock_key, lock_value, "NX", "PX", lock_timeout)
        if res == "OK" then
            return true
        elseif err then
            ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
            return false
        end
        -- Delay before retrying
        ngx.sleep(retry_delay / 1000) -- Convert milliseconds to seconds
    end
    return false -- Failed to acquire lock after max retries
end

-- Function to release a lock
local function release_lock(red, lock_key)
    red:del(lock_key)
end

-- Main rate limiting logic
local function rate_limit()
    local red = init_redis() -- Initialize Redis connection
    local token = get_token() -- Fetch the token from URL parameters

    -- Unique lock key for each user
    local lock_key = "rate_limit_lock:" .. token

    -- Try to acquire the lock with retries
    if not acquire_lock(red, lock_key) then
        ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE) -- TODO: have to discuss
    end

    -- Redis keys for token count and last access time
    local tokens_key = token .. ":tokens"
    local last_access_key = token .. ":last_access"

    -- Fetch current state from Redis
    local last_tokens = tonumber(red:get(tokens_key)) or bucket_capacity
    local now = ngx.now() * 1000 -- Current timestamp in milliseconds
    local last_access = tonumber(red:get(last_access_key)) or now

    -- Calculate the number of tokens to be added due to the elapsed time since the last access
    local elapsed = math.max(0, now - last_access)
    local add_tokens = math.floor(elapsed * refill_rate / 1000)
    local new_tokens = math.min(bucket_capacity, last_tokens + add_tokens)

    -- Calculate TTL for the Redis keys
    local ttl = math.floor(bucket_capacity / refill_rate * 2)

    -- Check if there are enough tokens for the request
    if new_tokens >= requested_tokens then
        -- Deduct tokens and update Redis state
        new_tokens = new_tokens - requested_tokens
        red:set(tokens_key, new_tokens, "EX", ttl)
        red:set(last_access_key, now, "EX", ttl)

        release_lock(red, lock_key)
        
        ngx.say("Request allowed")
    else
        release_lock(red, lock_key)
        -- Not enough tokens, rate limit the request
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429
    end
end

-- Run the rate limiter
rate_limit()
