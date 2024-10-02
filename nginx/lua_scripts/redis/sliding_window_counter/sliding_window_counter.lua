local redis = require "resty.redis"

-- Define the rate limiter parameters
local max_count = 15 -- Max requests allowed in the window
local window_length_secs = 10 -- Window size in seconds

-- Function to get the current time in milliseconds
local function get_current_time_ms()
    return ngx.now() * 1000
end

-- Initialize Redis
local redis_host = "redis"
local redis_port = 6379

local function init_redis()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    return red
end

-- Function to check if the request is allowed (sliding window algorithm)
local function allowed(token)
    local red = init_redis()

    -- Construct the Redis key using the token
    local redis_key = "sliding_window_log:" .. token
    local now = get_current_time_ms()

    -- Get the current sliding window for the user
    local sliding_window, err = red:lrange(redis_key, 0, -1)
    if err then
        ngx.log(ngx.ERR, "Failed to get sliding window from Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Remove timestamps that are outside the window
    for _, timestamp in ipairs(sliding_window) do
        if tonumber(timestamp) + (window_length_secs * 1000) < now then
            red:lpop(redis_key) -- Remove old timestamps
        else
            break -- Since Redis lists are ordered, stop when we reach valid timestamps
        end
    end

    -- Check if the number of requests exceeds the rate limit
    local request_count = red:llen(redis_key)
    if request_count >= max_count then
        -- Too many requests in the current window, reject
        return false
    else
        -- Add the current request timestamp to the sliding window
        red:rpush(redis_key, now)

        -- Set expiration time for the key to ensure Redis memory cleanup
        red:expire(redis_key, window_length_secs)
        return true
    end
end

-- Example usage: Fetch token from URL parameters and check if the request is allowed
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

if allowed(token) then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end
