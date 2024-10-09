local redis = require "resty.redis"

-- Define the rate limiter parameters
local window_size = 60 -- Total window size in seconds
local request_limit = 100 -- Max requests allowed in the window
local sub_window_count = 5 -- Number of subwindows
local sub_window_size = window_size / sub_window_count
local window_ttl = window_size + sub_window_size -- TTL for window keys

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

-- Function to check if the request is allowed
local function allowed(token)
    ngx.log(ngx.DEBUG, "Checking rate limit for token: " .. token)
    local now = ngx.time()
    ngx.log(ngx.DEBUG, "Current time: " .. now)
    
    -- Get or set the start time for this token
    local start_time_key = "rate_limit_start:" .. token
    local start_time, err = red:get(start_time_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get start time from Redis: ", err)
        return false -- Fail closed: don't allow the request if we can't check properly
    end
    
    if not start_time then
        start_time = now
        local ok, err = red:set(start_time_key, tostring(start_time))
        if not ok then
            ngx.log(ngx.ERR, "Failed to set start time in Redis: ", err)
            return false -- Fail closed
        end
    else
        start_time = tonumber(start_time)
        if not start_time then
            ngx.log(ngx.ERR, "Invalid start time in Redis. Raw value: " .. tostring(start_time))
            -- Attempt to reset the start time
            start_time = now
            local ok, err = red:set(start_time_key, tostring(start_time))
            if not ok then
                ngx.log(ngx.ERR, "Failed to reset invalid start time in Redis: ", err)
                return false -- Fail closed
            end
            ngx.log(ngx.WARN, "Reset start time for token: " .. token)
        end
    end
    
    ngx.log(ngx.DEBUG, "Start time for token " .. token .. ": " .. start_time)
    
    -- Calculate the current window based on the start time
    local time_since_start = now - start_time
    local current_window_key = math.floor(time_since_start / sub_window_size) * sub_window_size + start_time
    
    local current_count, err = red:get("rate_limit:" .. token .. ":" .. current_window_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get current count from Redis: ", err)
        return false -- Fail closed
    end
    current_count = tonumber(current_count) or 0

    -- Generate keys for previous windows dynamically
    local window_keys = {}
    for i = 1, sub_window_count do
        window_keys[i] = current_window_key - (i * sub_window_size)
    end

    -- Get counts from Redis for all windows
    local total_requests = current_count
    local elapsed_time = (now - start_time) % sub_window_size
    for i, window_key in ipairs(window_keys) do
        local window_count, err = red:get("rate_limit:" .. token .. ":" .. window_key)
        if err then
            ngx.log(ngx.ERR, "Failed to get window count from Redis: ", err)
            return false -- Fail closed
        end
        window_count = tonumber(window_count) or 0
        -- Apply weight only to the last window
        if i == sub_window_count then
            total_requests = total_requests + (sub_window_size - elapsed_time) / sub_window_size * window_count
        else
            total_requests = total_requests + window_count
        end
    end

    ngx.log(ngx.DEBUG, "Total requests for token " .. token .. ": " .. total_requests)

    -- Check if the total requests exceed the limit
    if total_requests + 1 <= request_limit then
        -- Increment the count for the current window
        local new_count, err = red:incr("rate_limit:" .. token .. ":" .. current_window_key)
        if err then
            ngx.log(ngx.ERR, "Failed to increment counter in Redis: ", err)
            return false -- Fail closed
        end
        
        -- Set TTL only if this is a new key (i.e., new_count == 1)
        if new_count == 1 then
            -- Use Redis transaction to set TTL for both window key and start_time_key
            red:expire("rate_limit:" .. token .. ":" .. current_window_key, window_ttl)
            red:expire(start_time_key, window_ttl)
            if not results then
                ngx.log(ngx.ERR, "Failed to set TTLs in Redis transaction: ", err)
                -- Note: We don't fail here as the counter was successfully incremented
            end
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
    ngx.status = ngx.HTTP_TOO_MANY_REQUESTS
    ngx.say("Rate limit exceeded")
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end
