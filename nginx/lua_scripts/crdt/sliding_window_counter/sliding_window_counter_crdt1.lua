local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis-enterprise-1"
local redis_port = 12000
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local window_size = 60 -- Total window size in seconds
local request_limit = 100 -- Max requests allowed in the window
local sub_window_count = 4 -- Number of subwindows

-- Helper function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, "Failed to connect to Redis: " .. err
    end
    return red
end

-- Helper function to close Redis connection
local function close_redis(red)
    local ok, err = red:set_keepalive(max_idle_timeout, pool_size)
    if not ok then
        return nil, err
    end
    return true
end

-- Helper function to get URL token
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Helper function to calculate the sub-window size and key
local function get_current_window_key()
    local now = ngx.time()
    local sub_window_size = window_size / sub_window_count
    local current_window_key = math.floor(now / sub_window_size) * sub_window_size
    return current_window_key, sub_window_size, now
end

-- Helper function to compute the total requests across sliding windows
local function get_total_requests(red, token, current_window_key, sub_window_size, now)
    -- Get current window count
    local current_count, err = red:get("rate_limit:" .. token .. ":" .. current_window_key)
    if err then
        return nil, "Failed to get current count: " .. err
    end
    current_count = tonumber(current_count) or 0

    -- Calculate total requests across all subwindows
    local total_requests = current_count
    local elapsed_time = now % sub_window_size

    for i = 1, sub_window_count do
        local previous_window_key = current_window_key - (i * sub_window_size)
        local previous_count, err = red:get("rate_limit:" .. token .. ":" .. previous_window_key)
        if err then
            return nil, "Failed to get previous window count: " .. err
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

-- Main rate limiting logic
local function check_rate_limit(red, token)
    -- Get current sub-window key and size
    local current_window_key, sub_window_size, now = get_current_window_key()

    -- Get total requests across sliding windows
    local total_requests, err = get_total_requests(red, token, current_window_key, sub_window_size, now)
    if not total_requests then
        return ngx.HTTP_INTERNAL_SERVER_ERROR, err
    end

    -- Check if the request limit is exceeded
    if total_requests + 1 > request_limit then
        return ngx.HTTP_TOO_MANY_REQUESTS
    end

    -- Increment the count for the current window
    local new_count, err = red:incr("rate_limit:" .. token .. ":" .. current_window_key)
    if err then
        return ngx.HTTP_INTERNAL_SERVER_ERROR, "Failed to increment Redis counter: " .. err
    end

    -- Set expiration for the current window
    local ok, err = red:expire("rate_limit:" .. token .. ":" .. current_window_key, window_size)
    if not ok then
        return ngx.HTTP_INTERNAL_SERVER_ERROR, "Failed to set expiration: " .. err
    end

    return ngx.HTTP_OK, "Request allowed"
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    -- Get token from request
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Initialize Redis connection
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Execute rate limiting logic with error handling
    local success, status, message = pcall(check_rate_limit, red, token)
    
    -- Always try to close the Redis connection
    local ok, close_err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", close_err)
    end

    -- Handle the results
    if not success then
        ngx.log(ngx.ERR, "Error executing rate limit check: ", status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if status == ngx.HTTP_OK then
        return
    else
        if message then
            ngx.log(ngx.ERR, message)
        end
        ngx.exit(status)
    end
end

-- Run the main function
main()