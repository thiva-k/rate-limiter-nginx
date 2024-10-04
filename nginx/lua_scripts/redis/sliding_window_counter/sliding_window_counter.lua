local redis = require "resty.redis"
local cjson = require "cjson"  

-- Define the rate limiter parameters
local window_size = 15 -- Window size in seconds
local request_limit = 10 -- Max requests allowed in the window
local number_of_sub_windows = 5 -- Number of subwindows (can be adjusted for granularity)
local sub_window_size = window_size / number_of_sub_windows -- Size of each subwindow

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
    local now = ngx.now()
    local redis_key_prefix = "sliding_window_counter:" .. token

    -- Get the last access time from Redis
    local last_access_time, err = red:get(redis_key_prefix .. ":last_access")
    if last_access_time == ngx.null then
        last_access_time = now -- Initialize to current time if no previous access exists
    else
        last_access_time = tonumber(last_access_time)
    end

    -- Calculate elapsed time since the last access
    local elapsed_time = now - last_access_time

    -- Initialize the subwindows in Redis if they don't exist
    local sub_windows_key = redis_key_prefix .. ":sub_windows"
    local sub_windows = red:get(sub_windows_key)
    if not sub_windows or sub_windows == ngx.null then
        sub_windows = {}
        for i = 1, number_of_sub_windows do
            sub_windows[i] = 0 -- Initialize all subwindows to 0 requests
        end
    else
        sub_windows = cjson.decode(sub_windows) -- Decode the JSON stored array
    end

    -- Update subwindow count if the elapsed time exceeds the subwindow size
    if elapsed_time >= sub_window_size then
        local current_sub_window_index = math.floor(now / sub_window_size) % number_of_sub_windows
        sub_windows[current_sub_window_index + 1] = 0 -- Reset the current subwindow count
    end

    -- Calculate the total requests in the sliding window
    local total_requests = 0
    for _, count in ipairs(sub_windows) do
        total_requests = total_requests + count
    end

    -- Check if the total requests exceed the limit
    if total_requests < request_limit then
        -- Increment the count for the current subwindow
        local current_sub_window_index = math.floor(now / sub_window_size) % number_of_sub_windows
        sub_windows[current_sub_window_index + 1] = sub_windows[current_sub_window_index + 1] + 1
        
        -- Update the subwindows in Redis
        local ok, err = red:set(sub_windows_key, cjson.encode(sub_windows))
        if not ok then
            ngx.log(ngx.ERR, "Failed to update sub windows in Redis: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        -- Update the last access time in Redis
        ok, err = red:set(redis_key_prefix .. ":last_access", now)
        if not ok then
            ngx.log(ngx.ERR, "Failed to update last access time in Redis: ", err)
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
