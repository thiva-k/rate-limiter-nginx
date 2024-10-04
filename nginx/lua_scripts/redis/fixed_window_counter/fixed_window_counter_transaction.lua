local redis = require "resty.redis"

-- Global variables
local redis_host = "redis"
local redis_port = 6379
local rate_limit = 500 -- 50 requests per minute
local window_size = 60 -- 60 second window

-- Function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, "Failed to connect to Redis: " .. err
    end

    return red
end

-- Function to retrieve the token from URL parameters
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Function to get the current count for a given key
local function get_current_count(red, redis_key)
    local count, err = red:get(redis_key)
    if err then
        return nil, "Failed to get counter from Redis: " .. err
    end

    -- Convert count to number or set to 0 if it doesn't exist
    return tonumber(count) or 0
end

-- Function to perform rate limiting transaction
local function perform_rate_limiting_transaction(red, redis_key)
    -- Use Redis MULTI to begin a transaction
    local ok, err = red:multi()
    if not ok then
        return nil, "Failed to start Redis transaction: " .. err
    end

    -- Increment the counter
    ok, err = red:incr(redis_key)
    if not ok then
        return nil, "Failed to increment counter in Redis: " .. err
    end

    -- Set expiration time only if it's a new key (NX flag)
    ok, err = red:expire(redis_key, window_size, "NX")
    if not ok then
        return nil, "Failed to set expiration for key in Redis: " .. err
    end

    -- Execute the Redis transaction
    local results, err = red:exec()
    if not results then
        return nil, "Failed to execute Redis transaction: " .. err
    end

    return results
end

-- Main function to check rate limit
local function check_rate_limit()
    -- Initialize Redis connection
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Get token from URL parameters
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Construct the Redis key using only the token
    local redis_key = "rate_limit:" .. token

    -- Get current count
    local count, err = get_current_count(red, redis_key)
    if not count then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Check if rate limit is exceeded
    if count >= rate_limit then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    -- Perform rate limiting transaction
    local results, err = perform_rate_limiting_transaction(red, redis_key)
    if not results then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
end

-- Main execution
check_rate_limit()