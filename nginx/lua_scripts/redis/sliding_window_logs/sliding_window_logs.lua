local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local rate_limit = 100 -- 500 requests per minute
local window_size = 60 -- 60 second window

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
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Main rate limiting logic
local function check_rate_limit(red, token)
    -- Construct the Redis key using the token
    local key = "rate_limit:" .. token

    -- Get the current timestamp
    local current_time = ngx.now()

    -- Remove elements outside the current window
    local removed, err = red:zremrangebyscore(key, 0, current_time - window_size)
    if err then
        ngx.log(ngx.ERR, "Failed to remove old entries: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Count the number of elements in the current window
    local count, err = red:zcard(key)
    if err then
        ngx.log(ngx.ERR, "Failed to count entries: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Check if the number of requests exceeds the rate limit
    if count >= rate_limit then
        return ngx.HTTP_TOO_MANY_REQUESTS
    end

    -- Add the new element
    local added, err = red:zadd(key, current_time, current_time)
    if err then
        ngx.log(ngx.ERR, "Failed to add new entry: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Set expiration
    local expired, err = red:expire(key, window_size)
    if err then
        ngx.log(ngx.ERR, "Failed to set expiration: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    return ngx.HTTP_OK
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local res, status = pcall(check_rate_limit, red, token)
    local ok, err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", err)
    end

    if not res then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif status == ngx.HTTP_TOO_MANY_REQUESTS then
        ngx.exit(status)
    end
end

-- Run the main function
main()