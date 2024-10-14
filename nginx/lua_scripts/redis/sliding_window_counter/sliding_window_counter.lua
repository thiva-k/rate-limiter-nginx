local redis = require "resty.redis"

-- Define the rate limiter parameters
local window_size = 60 -- Total window size in seconds
local request_limit = 100 -- Max requests allowed in the window
local sub_window_count = 4 -- Number of subwindows

-- Initialize Redis connection
local redis_host = "redis"
local redis_port = 6379

local red = redis:new()
red:set_timeout(1000) -- 1 second timeout

local ok, err = red:connect(redis_host, redis_port)
if not ok then
    ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Function to check if the request is allowed (sliding window counter algorithm)
local function allowed(token)
    local now = ngx.time()
    local sub_window_size = window_size / sub_window_count -- Calculate sub-window size based on count
    local current_window_key = math.floor(now / sub_window_size) * sub_window_size -- Current sub-window key
    local current_count, err = red:get("rate_limit:" .. token .. ":" .. current_window_key)
    current_count = tonumber(current_count) or 0

    -- Generate keys for previous windows dynamically
    local window_keys = {}
    for i = 1, sub_window_count  do
        window_keys[i] = current_window_key - (i * sub_window_size)
    end

    -- Get counts from Redis for all windows
    local total_requests = current_count
    local elapsed_time = now % sub_window_size
    for i, window_key in ipairs(window_keys) do
        local window_count, err = red:get("rate_limit:" .. token .. ":" .. window_key)
        window_count = tonumber(window_count) or 0
        -- Apply weight only to the last window
        if i == sub_window_count then
            total_requests = total_requests + (sub_window_size - elapsed_time) / sub_window_size * window_count
        else
            total_requests = total_requests + window_count
        end
    end

    -- Check if the total requests exceed the limit
    if total_requests + 1 <= request_limit then
        -- Increment the count for the current window
        local new_count, err = red:incr("rate_limit:" .. token .. ":" .. current_window_key)
        if err then
            ngx.log(ngx.ERR, "Failed to increment counter in Redis: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        return true -- Request allowed
    else
        return false -- Request not allowed
    end
end

local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

if allowed(token) then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- Return 429 if rate limit exceeded
end