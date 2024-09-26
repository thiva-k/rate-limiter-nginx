local redis = require "resty.redis"

-- Initialization
local redis_host = "redis"
local redis_port = 6379

local red = redis:new()
red:set_timeout(1000) -- 1 second timeout

local ok, err = red:connect(redis_host, redis_port)
if not ok then
    ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Fetch the token from the URL parameter
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

-- Input parameters
local window_size = 60                 -- 60 seconds total window size
local request_limit = 5                -- Max 5 requests allowed in the window
local number_of_sub_windows = 6        -- Divide the window into 6 sub-windows (10 seconds each)
local sub_window_size = window_size / number_of_sub_windows  -- Sub-window size in seconds

-- Construct Redis keys
local redis_key_sub_windows = "rate_limit:" .. token .. ":sub_windows"
local redis_key_last_check = "rate_limit:" .. token .. ":last_check"
local current_time = ngx.now()

-- Fetch data from Redis (sub-window counters and last check time)
local sub_windows, err = red:get(redis_key_sub_windows)
if sub_windows == ngx.null or not sub_windows then
    sub_windows = {0, 0, 0, 0, 0, 0}  -- Initialize sub-windows if not present in Redis
else
    sub_windows = cjson.decode(sub_windows) -- Decode JSON string back to table
end

local last_check_time, err = red:get(redis_key_last_check)
if last_check_time == ngx.null or not last_check_time then
    last_check_time = current_time    -- Initialize last check time if not found in Redis
else
    last_check_time = tonumber(last_check_time)
end

-- Function to allow or deny the request
local function ALLOW_REQUEST()
    local elapsed_time = current_time - last_check_time  -- Calculate elapsed time
    
    -- Update sub-windows if enough time has passed (move to next sub-window)
    while elapsed_time >= sub_window_size do
        -- Move to the next sub-window
        table.remove(sub_windows, 1)   -- Remove the oldest sub-window
        table.insert(sub_windows, 0)   -- Add a new sub-window (empty)
        
        last_check_time = last_check_time + sub_window_size
        elapsed_time = current_time - last_check_time  -- Update elapsed time
    end

    -- Calculate total number of requests in the window
    local total_requests = 0
    for i = 1, number_of_sub_windows do
        total_requests = total_requests + sub_windows[i]
    end

    -- Check if the total number of requests exceeds the limit
    if total_requests < request_limit then
        sub_windows[#sub_windows] = sub_windows[#sub_windows] + 1  -- Increment the current sub-window
        return true  -- Request allowed
    else
        return false  -- Request not allowed (rate limit exceeded)
    end
end

-- Call the function to check if the request is allowed
local allowed = ALLOW_REQUEST()

if allowed then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)  -- 429 Too Many Requests
end

-- Save the updated sub-windows and last check time back to Redis
local ok, err = red:set(redis_key_sub_windows, cjson.encode(sub_windows))  -- Save sub-windows as JSON
if not ok then
    ngx.log(ngx.ERR, "Failed to save sub-windows to Redis: ", err)
end

local ok, err = red:set(redis_key_last_check, last_check_time)  -- Save last check time
if not ok then
    ngx.log(ngx.ERR, "Failed to save last check time to Redis: ", err)
end

-- Optional: Set expiration time for Redis keys to automatically clean them up
red:expire(redis_key_sub_windows, window_size * 2)  -- Expire after twice the window size
red:expire(redis_key_last_check, window_size * 2)
