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

-- TODO: Handle race condition among nginx worker processes

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

-- Main rate limiting logic
local function check_rate_limit(red, token)
    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    local results, err = red:mget(tokens_key, last_access_key)
    if not results then
        return nil, "Failed to execute Redis MGET: " .. err
    end

    -- This code internally scales the request rate, bucket capacity, and requested tokens by a factor of 1000.
    -- This scaling is done to facilitate operations in milliseconds, providing finer granularity and precision
    -- in rate limiting calculations.
    local now = ngx.now() * 1000 -- Current timestamp in milliseconds
    local last_token_count = tonumber(results[1]) or (bucket_capacity * 1000)
    local last_access_time = tonumber(results[2]) or now

    -- Calculate the number of tokens to be added due to the elapsed time since the last access
    local elapsed_time_ms = math.max(0, now - last_access_time)
    local tokens_to_add = elapsed_time_ms * refill_rate
    local new_token_count = math.floor(math.min(bucket_capacity * 1000, last_token_count + tokens_to_add))

    -- Calculate TTL for the Redis keys in seconds
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

    local pcall_status, check_rate_limit_result, message, remaining_tokens, next_reset_time = pcall(check_rate_limit, red, token)

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

-- Run the main function
main()
