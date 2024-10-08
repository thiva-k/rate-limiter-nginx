local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout

-- Token bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local refill_rate = 1 -- Tokens generated per second
local requested_tokens = 1 -- Number of tokens required per request

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

-- Helper function to get URL token
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Redis script to implement token bucket algorithm
local function get_token_bucket_script()
    return [[
        local tokens_key = KEYS[1]
        local last_access_key = KEYS[2]
        local bucket_capacity = tonumber(ARGV[1])
        local refill_rate = tonumber(ARGV[2])
        local now = tonumber(ARGV[3])
        local requested = tonumber(ARGV[4])
        local ttl = tonumber(ARGV[5])

        local last_tokens = tonumber(redis.call("get", tokens_key)) or bucket_capacity
        local last_access = tonumber(redis.call("get", last_access_key)) or now

        local elapsed = math.max(0, now - last_access)
        local add_tokens = math.floor(elapsed * refill_rate / 1000)
        local new_tokens = math.min(bucket_capacity, last_tokens + add_tokens)

        if new_tokens >= requested then
            new_tokens = new_tokens - requested
            redis.call("set", tokens_key, new_tokens, "EX", ttl)
            redis.call("set", last_access_key, now, "EX", ttl)
            return 1
        else
            return 0
        end
    ]]
end

-- Function to load the script into Redis if not already cached
local function load_script_to_redis(red, script)
    local sha = ngx.shared.my_cache:get("rate_limit_script_sha")
    if not sha then
        local new_sha, err = red:script("LOAD", script)
        if not new_sha then
            return nil, err
        end
        ngx.shared.my_cache:set("rate_limit_script_sha", new_sha)
        sha = new_sha
    end
    return sha
end

-- Execute the token bucket logic atomically
local function execute_token_bucket(red, sha, tokens_key, last_access_key, bucket_capacity, refill_rate, requested_tokens, ttl)
    local now = ngx.now() * 1000 -- Current time in milliseconds
    local result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, refill_rate, now, requested_tokens, ttl)

    if err and err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        ngx.shared.my_cache:delete("rate_limit_script_sha")
        sha, err = load_script_to_redis(red, get_token_bucket_script())
        if not sha then
            return nil, err
        end
        result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, refill_rate, now, requested_tokens, ttl)
    end

    if err then
        return nil, err
    end

    return result
end

-- Main rate limiting logic
local function rate_limit()
    -- Initialize Redis connection
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Get token from the request URL
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    -- Calculate TTL for the Redis keys
    local ttl = math.floor(bucket_capacity / refill_rate * 2)

    -- Load or retrieve the Lua script SHA
    local script = get_token_bucket_script()
    local sha, err = load_script_to_redis(red, script)
    if not sha then
        ngx.log(ngx.ERR, "Failed to load script: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Execute token bucket logic
    local result, err = execute_token_bucket(red, sha, tokens_key, last_access_key, bucket_capacity, refill_rate, requested_tokens, ttl)
    if not result then
        ngx.log(ngx.ERR, "Failed to run rate limiting script: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Handle the result
    if result == 1 then
        ngx.say("Request allowed")
    else
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429 Too Many Requests
    end
end

-- Run the rate limiter
rate_limit()