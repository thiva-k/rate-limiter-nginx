local redis = require "resty.redis"

-- Global variables
local redis_host = "redis"
local redis_port = 6379
local rate_limit = 500 -- 500 requests per minute
local window_size = 60 -- 60 second window

local function init_redis()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, err
    end

    return red
end

local function get_token()
    local token = ngx.var.arg_token
    if not token then
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

    -- Get the current timestamp and round it down to the nearest minute
    local current_time = ngx.now()
    local window_start = math.floor(current_time / window_size) * window_size

    -- Construct the Redis key using the token and the window start time
    local redis_key = string.format("rate_limit:%s:%d", token, window_start)

    -- Get the current count
    local count, err = red:get(redis_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get counter from Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Convert count to number or set to 0 if it doesn't exist
    count = tonumber(count) or 0

    -- Check if the number of requests exceeds the rate limit
    if count >= rate_limit then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    -- Increment the counter only if the request is to be allowed
    local new_count, err = red:incr(redis_key)
    if err then
        ngx.log(ngx.ERR, "Failed to increment counter in Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Set the expiration time for the Redis key if it's a new key
    if new_count == 1 then
        local remaining_time = window_size - (current_time % window_size)
        local ok, err = red:expire(redis_key, math.ceil(remaining_time))
        if not ok then
            ngx.log(ngx.ERR, "Failed to set expiration for key in Redis: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    end
end

-- Main execution
check_rate_limit()