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

-- Helper function to remove old entries and get current count
local function remove_old_entries_and_count(red, key, current_time)
    red:multi()
    red:zremrangebyscore(key, 0, current_time - window_size)
    red:zcard(key)
    local results, err = red:exec()
    if not results then
        return nil, "Failed to execute Redis transaction: " .. err
    end
    return results[2] -- Return the count
end

-- Helper function to add new entry with expiration
local function add_new_entry(red, key, current_time)
    red:multi()
    red:zadd(key, current_time, current_time)
    red:expire(key, window_size)
    local results, err = red:exec()

    if not results then
        return nil, "Failed to execute Redis transaction: " .. err
    end
    return true
end

-- Main rate limiting logic
local function check_rate_limit(red, token)
    local key = "rate_limit:" .. token
    local current_time = ngx.now()

    -- Remove old entries and get current count
    local count, err = remove_old_entries_and_count(red, key, current_time)
    if not count then
        return ngx.HTTP_INTERNAL_SERVER_ERROR, err
    end

    -- Check if we're over the limit
    if count >= rate_limit then
        return ngx.HTTP_TOO_MANY_REQUESTS
    end

    -- Add new entry
    local success, err = add_new_entry(red, key, current_time)
    if not success then
        return ngx.HTTP_INTERNAL_SERVER_ERROR, err
    end

    return ngx.HTTP_OK
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    -- Get token from request
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

    -- Execute rate limiting logic with error handling
    local success, status, err = pcall(check_rate_limit, red, token)
    
    -- Always try to close the Redis connection
    local ok, close_err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", close_err)
    end

    -- Handle the results
    if not success then
        ngx.log(ngx.ERR, "Error executing rate limit check: ", status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif err then
        ngx.log(ngx.ERR, "Rate limiting error: ", err)
        ngx.exit(status)
    else
        ngx.exit(status)
    end
end

-- Run the main function
main()