local redis = require "resty.redis"
local cjson = require "cjson"

-- Define the rate limiter parameters
local window_size = 60 -- Total window size in seconds
local request_limit = 50 -- Max requests allowed in the window
local sub_window_size = 15 -- Size of each subwindow

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
    local current_window_key = math.floor(now / sub_window_size) * sub_window_size -- Current 15-second key
    local previous_window_1_key = current_window_key - sub_window_size -- Last full window key
    local previous_window_2_key = current_window_key - (2 * sub_window_size) -- Two windows before key
    local previous_window_3_key = current_window_key - (3 * sub_window_size) -- Three windows before key
    local previous_window_4_key = current_window_key - (4 * sub_window_size) -- Four windows before key

    -- Get the counts from Redis
    local current_count, err = red:get("rate_limit:" .. token .. ":" .. current_window_key)
    local previous_count_1, err = red:get("rate_limit:" .. token .. ":" .. previous_window_1_key)
    local previous_count_2, err = red:get("rate_limit:" .. token .. ":" .. previous_window_2_key)
    local previous_count_3, err = red:get("rate_limit:" .. token .. ":" .. previous_window_3_key)
    local previous_count_4, err = red:get("rate_limit:" .. token .. ":" .. previous_window_4_key)

    current_count = tonumber(current_count) or 0
    previous_count_1 = tonumber(previous_count_1) or 0
    previous_count_2 = tonumber(previous_count_2) or 0
    previous_count_3 = tonumber(previous_count_3) or 0
    previous_count_4 = tonumber(previous_count_4) or 0

    -- Check how much time has passed in the current window
    local elapsed_time = now % sub_window_size

    -- Calculate weighted count from the last window
    local weighted_count = (15 - elapsed_time) / 15 * previous_count_4

    -- Calculate total requests in the 60 seconds window
    local total_requests = current_count + previous_count_1 + previous_count_2 + previous_count_3 + weighted_count

    -- Check if the total requests exceed the limit
    if total_requests < request_limit then
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

-- Example usage: Fetch token from URL parameters and check if the request is allowed
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