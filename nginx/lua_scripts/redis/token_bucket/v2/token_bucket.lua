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

-- Main rate limiting logic using Redis sorted sets
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

    -- Redis sorted set key for tracking request timestamps
    local sorted_set_key = "rate_limit:" .. token .. ":timestamps"

    local now = ngx.now() -- Current timestamp in seconds
    local window_start = now - 1 -- 1 second sliding window

    -- Remove timestamps that are outside the sliding window and get the current count in a pipeline
    red:init_pipeline()
    red:zremrangebyscore(sorted_set_key, "-inf", window_start)
    red:zcard(sorted_set_key)
    local results, err = red:commit_pipeline()
    if not results then
        ngx.log(ngx.ERR, "Failed to execute Redis pipeline: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Extract the current count from the pipeline results
    local current_count = results[2]
    if not current_count then
        ngx.log(ngx.ERR, "Failed to get sorted set count from pipeline results")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Check if the request can be allowed
    if current_count < bucket_capacity then
        -- Allow the request and add the current timestamp to the sorted set
        red:init_pipeline()
        red:zadd(sorted_set_key, now, now)
        red:expire(sorted_set_key, 10)
        local results, err = red:commit_pipeline()
        if not results then
            ngx.log(ngx.ERR, "Failed to execute Redis pipeline: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        ngx.say("Request allowed")
    else
        -- Rate limit the request
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429
    end
end

-- Run the rate limiter
rate_limit()
