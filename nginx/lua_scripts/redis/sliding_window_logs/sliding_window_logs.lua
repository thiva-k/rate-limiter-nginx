local redis = require "resty.redis"

-- Global variables
local redis_host = "redis"
local redis_port = 6379
local rate_limit = 500 -- 500 requests per minute
local window_size = 60 -- 1 minute window

local function init_redis()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
        return nil, err
    end

    return red
end

local function get_token()
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        return nil, "Token not provided"
    end
    return token
end

local function check_rate_limit()
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Construct the Redis key using the token
    local key = "rate_limit:" .. token

    -- Get the current timestamp
    local current_time = ngx.now()

    -- Remove elements outside the current window
    local removed, err = red:zremrangebyscore(key, 0, current_time - window_size)
    if err then
        ngx.log(ngx.ERR, "Failed to remove old entries: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Count the number of elements in the current window
    local count, err = red:zcard(key)
    if err then
        ngx.log(ngx.ERR, "Failed to count entries: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Check if the number of requests exceeds the rate limit
    if count >= rate_limit then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    -- Add the new element
    local added, err = red:zadd(key, current_time, current_time)
    if err then
        ngx.log(ngx.ERR, "Failed to add new entry: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Set expiration
    local expired, err = red:expire(key, window_size)
    if err then
        ngx.log(ngx.ERR, "Failed to set expiration: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
end

-- Main execution
check_rate_limit()