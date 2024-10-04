local redis = require "resty.redis"

-- Define the rate limiter parameters
local max_count = 15 -- Max requests allowed in the window
local window_length_secs = 10 -- Window size in seconds
local granularity = 1 -- Size of each small interval in seconds

-- Function to get the current time in milliseconds
local function get_current_time_secs()
    return ngx.now()
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

-- Function to check if the request is allowed (sliding window counter algorithm)
local function allowed(token)
    local red = init_redis()

    -- Current time in seconds (rounded to nearest interval)
    local now = get_current_time_secs()
    local current_bucket = math.floor(now / granularity)

    -- Construct Redis keys for the sliding window buckets
    local redis_key_prefix = "sliding_window_counter:" .. token

    -- Sum up requests from buckets within the sliding window
    local total_requests = 0
    for i = 0, window_length_secs / granularity - 1 do
        local bucket_key = redis_key_prefix .. ":" .. (current_bucket - i)
        local count, err = red:get(bucket_key)
        if err then
            ngx.log(ngx.ERR, "Failed to get request count from Redis: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        total_requests = total_requests + (tonumber(count) or 0)
    end

    -- Check if the number of requests exceeds the rate limit
    if total_requests >= max_count then
        -- Too many requests in the current window, reject
        return false
    else
        -- Increment the counter for the current bucket
        local current_bucket_key = redis_key_prefix .. ":" .. current_bucket
        local count, err = red:incr(current_bucket_key)
        if err then
            ngx.log(ngx.ERR, "Failed to increment request count: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        -- Set the expiration for this bucket to the window size
        red:expire(current_bucket_key, window_length_secs)
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
