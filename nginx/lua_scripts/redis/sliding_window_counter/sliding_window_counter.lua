local redis = require "resty.redis"

-- Global variables
local redis_host = "redis"
local redis_port = 6379
local window_size = 60 -- Total window size in seconds
local request_limit = 100 -- Max requests allowed in the window
local sub_window_count = 4 -- Number of subwindows

-- Initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, err
    end

    return red
end

-- Fetch the token from query parameters
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Function to calculate the sub-window size and key
local function get_current_window_key()
    local now = ngx.time()
    local sub_window_size = window_size / sub_window_count
    local current_window_key = math.floor(now / sub_window_size) * sub_window_size
    return current_window_key, sub_window_size, now
end

-- Function to compute the total requests across the sliding windows
local function get_total_requests(red, token, current_window_key, sub_window_size, now)
    local current_count, err = red:get("rate_limit:" .. token .. ":" .. current_window_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get current count: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    current_count = tonumber(current_count) or 0

    -- Generate keys for previous subwindows
    local total_requests = current_count
    local elapsed_time = now % sub_window_size

    for i = 1, sub_window_count do
        local previous_window_key = current_window_key - (i * sub_window_size)
        local previous_count, err = red:get("rate_limit:" .. token .. ":" .. previous_window_key)
        if err then
            ngx.log(ngx.ERR, "Failed to get previous window count: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        previous_count = tonumber(previous_count) or 0

        -- Apply weight for the oldest window
        if i == sub_window_count then
            total_requests = total_requests + ((sub_window_size - elapsed_time) / sub_window_size) * previous_count
        else
            total_requests = total_requests + previous_count
        end
    end

    return total_requests
end

-- Function to check if a request is allowed
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

    -- Get current sub-window key and size
    local current_window_key, sub_window_size, now = get_current_window_key()

    -- Get total requests across sliding windows
    local total_requests = get_total_requests(red, token, current_window_key, sub_window_size, now)

    -- Check if the request limit is exceeded
    if total_requests + 1 <= request_limit then
        -- Increment the count for the current window
        local new_count, err = red:incr("rate_limit:" .. token .. ":" .. current_window_key)
        if err then
            ngx.log(ngx.ERR, "Failed to increment Redis counter: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        ngx.say("Request allowed")
    else
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429 Too Many Requests
    end
end

-- Main execution, directly calling check_rate_limit()
check_rate_limit()
