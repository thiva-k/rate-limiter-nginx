local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Token bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local refill_rate = 1 -- Tokens generated per second
local requested_tokens = 1 -- Number of tokens required per request

-- Helper function to initialize Redis connection
local function init_redis()
    local red = redis:new()
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
local function rate_limit(red, token)
    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    local results, err = red:mget(tokens_key, last_access_key)
    if not results then
        return nil, "Failed to execute Redis MGET: " .. err
    end

    local now = ngx.now() * 1000 -- Current timestamp in milliseconds
    local last_tokens = tonumber(results[1]) or bucket_capacity
    local last_access = tonumber(results[2]) or now

    -- Calculate the number of tokens to be added due to the elapsed time since the last access
    local elapsed = math.max(0, now - last_access)
    local add_tokens = elapsed * refill_rate / 1000
    local new_tokens = math.floor(math.min(bucket_capacity, last_tokens + add_tokens) * 1000 + 0.5) / 1000

    -- Calculate TTL for the Redis keys
    local ttl = math.floor(bucket_capacity / refill_rate * 2)

    -- Check if there are enough tokens for the request
    if new_tokens >= requested_tokens then
        -- Deduct tokens and update Redis state
        new_tokens = new_tokens - requested_tokens

        red:init_pipeline()
        red:set(tokens_key, new_tokens, "EX", ttl)
        red:set(last_access_key, now, "EX", ttl)
        local results, err = red:commit_pipeline()
        if not results then
            return nil, "Failed to execute Redis pipeline: " .. err
        end

        return true, "allowed", new_tokens, now
    else
        -- Not enough tokens, rate limit the request
        return true, "rejected", new_tokens, now
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

    local pcall_status, rate_limit_result, message, remaining_tokens, last_access = pcall(rate_limit, red, token)

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
    else
        ngx.header["X-RateLimit-Remaining"] = remaining_tokens
        ngx.header["X-RateLimit-Limit"] = bucket_capacity
        ngx.header["X-RateLimit-Reset"] = math.floor((last_access / 1000) + (1 / refill_rate))

        if message == "rejected" then
            ngx.log(ngx.ERR, "Rate limit exceeded for token: ", token)
            ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
        else
            ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
        end
    end

end

-- Run the main function
main()
