local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout

-- Token bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local refill_rate = 1 -- Tokens generated per second

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

-- Redis script to implement sorted set-based rate limiting
local function get_sorted_set_rate_limit_script()
    return [[
        local sorted_set_key = KEYS[1]
        local now = tonumber(ARGV[1])
        local window_start = tonumber(ARGV[2])
        local bucket_capacity = tonumber(ARGV[3])
        local ttl = tonumber(ARGV[4])

        -- Remove old timestamps from the sorted set
        redis.call("zremrangebyscore", sorted_set_key, "-inf", window_start)

        -- Get the current count of requests in the sliding window
        local current_count = redis.call("zcard", sorted_set_key)

        -- If the current count is below the bucket capacity, allow the request
        if current_count < bucket_capacity then
            -- Add the current timestamp to the sorted set and set TTL
            redis.call("zadd", sorted_set_key, now, now)
            redis.call("expire", sorted_set_key, ttl)
            return 1 -- Request allowed
        else
            return 0 -- Rate limit the request
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

-- Execute the rate limiting logic atomically using sorted sets
local function execute_sorted_set_rate_limit(red, sha, sorted_set_key, now, window_start, bucket_capacity, ttl)
    local result, err = red:evalsha(sha, 1, sorted_set_key, now, window_start, bucket_capacity, ttl)

    if err and err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        ngx.shared.my_cache:delete("rate_limit_script_sha")
        sha, err = load_script_to_redis(red, get_sorted_set_rate_limit_script())
        if not sha then
            return nil, err
        end
        result, err = red:evalsha(sha, 1, sorted_set_key, now, window_start, bucket_capacity, ttl)
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

    -- Load or retrieve the Lua script SHA
    local script = get_sorted_set_rate_limit_script()
    local sha, err = load_script_to_redis(red, script)
    if not sha then
        ngx.log(ngx.ERR, "Failed to load script: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Redis sorted set key for tracking request timestamps
    local sorted_set_key = "rate_limit:" .. token .. ":timestamps"

    -- Calculate TTL for the Redis key
    local ttl = math.floor(bucket_capacity / refill_rate * 2)
    local window_size = 1 / refill_rate
    local now = ngx.now() -- Current timestamp in seconds
    local window_start = now - window_size -- 1 second sliding window

    -- Execute the rate limiting logic atomically
    local result, err = execute_sorted_set_rate_limit(red, sha, sorted_set_key, now, window_start, bucket_capacity, ttl)
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
