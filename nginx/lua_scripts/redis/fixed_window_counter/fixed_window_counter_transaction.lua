local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local rate_limit = 500 -- 500 requests per minute
local window_size = 60 -- 60 second window

-- Helper function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, "Failed to connect to Redis: " .. err
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
local function increment_transaction(red, redis_key, remaining_time)
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

    -- Set expiration time only if it's a new key (when count becomes 1)
    ok, err = red:expire(redis_key, math.ceil(remaining_time), "NX")
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

-- Main rate limiting logic
local function check_rate_limit(red, token)
    
    local service_name = ngx.var.service_name
    local http_method = ngx.var.request_method

    -- Get the current timestamp and round it down to the nearest minute
    local current_time = ngx.now()
    local window_start = math.floor(current_time / window_size) * window_size

    -- Construct the Redis key using the token, http_method, service_name and the window start time
    local redis_key = string.format("rate_limit:%s:%s:%s:%d", token, http_method, service_name, window_start)

    -- Get current count
    local count, err = get_current_count(red, redis_key)
    if not count then
        return nil, err
    end

    -- Check if rate limit is exceeded
    if count >= rate_limit then
        return ngx.HTTP_TOO_MANY_REQUESTS
    end

    -- Calculate remaining time in the current window
    local remaining_time = window_size - (current_time % window_size)

    -- Perform rate limiting transaction
    local results, err = increment_transaction(red, redis_key, remaining_time)
    if not results then
        return nil, err
    end

    return ngx.HTTP_OK
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    -- Get token from URL parameters
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Initialize Redis connection
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Run rate limiting check with error handling
    local res, status = pcall(check_rate_limit, red, token)
    
    -- Properly close Redis connection
    local ok, close_err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", close_err)
    end

    -- Handle any errors from the rate limiting check
    if not res then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif status == ngx.HTTP_TOO_MANY_REQUESTS then
        ngx.exit(status)
    end
end

-- Run the main function
main()