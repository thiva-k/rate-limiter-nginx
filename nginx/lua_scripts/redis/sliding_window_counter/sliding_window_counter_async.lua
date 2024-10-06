local redis = require "resty.redis"
local cjson = require "cjson"

-- Define rate limiter parameters
local window_size = 15 -- Window size in seconds
local request_limit = 10 -- Max requests allowed in the window
local number_of_sub_windows = 5 -- Number of subwindows for granularity
local sub_window_size = window_size / number_of_sub_windows -- Size of each subwindow
local batch_size = 5 -- Sync with Redis after this number of requests

-- Redis connection parameters
local redis_host = "redis"
local redis_port = 6379

-- Initialize Redis connection (once, globally)
local red = redis:new()
red:set_timeout(1000) -- 1 second timeout

local ok, err = red:connect(redis_host, redis_port)
if not ok then
    ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Keep Redis connection alive
local function keep_redis_alive(redis_connection)
    local ok, err = redis_connection:set_keepalive(10000, 100) -- Keep connection alive for 10 seconds
    if not ok then
        ngx.log(ngx.ERR, "Failed to set keepalive for Redis: ", err)
    end
end

-- Fetch subwindows and total count from Redis
local function fetch_redis_data(token)
    local redis_key_prefix = "sliding_window_counter:" .. token
    local sub_windows_key = redis_key_prefix .. ":sub_windows"
    local total_count_key = redis_key_prefix .. ":total_count"

    -- Fetch subwindows and total count
    local redis_sub_windows = red:get(sub_windows_key)
    if redis_sub_windows == ngx.null then
        redis_sub_windows = {}
        for i = 1, number_of_sub_windows do
            redis_sub_windows[i] = 0
        end
    else
        redis_sub_windows = cjson.decode(redis_sub_windows)
    end

    local redis_total_count = red:get(total_count_key)
    if redis_total_count == ngx.null then
        redis_total_count = 0
    else
        redis_total_count = tonumber(redis_total_count)
    end

    return redis_sub_windows, redis_total_count
end

-- Sync changes to Redis after the batch limit is reached
local function sync_with_redis(token, local_sub_windows, local_total_count, redis_sub_windows)
    local redis_key_prefix = "sliding_window_counter:" .. token
    local sub_windows_key = redis_key_prefix .. ":sub_windows"
    local total_count_key = redis_key_prefix .. ":total_count"

    -- Combine local and Redis subwindow values before syncing
    for i = 1, number_of_sub_windows do
        redis_sub_windows[i] = redis_sub_windows[i] + local_sub_windows[i]
    end

    -- Sync subwindows to Redis
    local ok, err = red:set(sub_windows_key, cjson.encode(redis_sub_windows))
    if not ok then
        ngx.log(ngx.ERR, "Failed to update Redis subwindows: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Sync total count to Redis
    ok, err = red:set(total_count_key, local_total_count)
    if not ok then
        ngx.log(ngx.ERR, "Failed to update Redis total count: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Reset batch count after sync
    ngx.shared.rate_limit_dict:set("batch_count:" .. token, 0)

    return true
end

-- Calculate the sliding window total (combined Redis and local values)
local function calculate_sliding_window_total(redis_sub_windows, local_sub_windows, now, last_access_time)
    local total = 0
    local elapsed_time = now - last_access_time

    for i = 1, number_of_sub_windows do
        -- Determine the window's age
        local window_age = elapsed_time - ((i - 1) * sub_window_size)
        if window_age < sub_window_size and window_age > 0 then
            local proportion = (sub_window_size - window_age) / sub_window_size
            -- Combine Redis and local subwindow values
            total = total + ((redis_sub_windows[i] + local_sub_windows[i]) * proportion)
        end
    end

    return total
end

-- Main rate limiter function
local function allowed(token)
    local shared_dict = ngx.shared.rate_limit_dict
    local now = ngx.now()

    -- Sliding window data keys in shared memory
    local sub_windows_key = "sub_windows:" .. token
    local last_access_key = "last_access:" .. token
    local batch_count_key = "batch_count:" .. token
    local local_total_count_key = "total_count:" .. token

    -- Get local data from shared memory
    local local_sub_windows = shared_dict:get(sub_windows_key)
    local last_access_time = shared_dict:get(last_access_key)
    local batch_count = shared_dict:get(batch_count_key)
    local local_total_count = shared_dict:get(local_total_count_key)

    -- Fetch Redis data (subwindows and total count)
    local redis_sub_windows, redis_total_count = fetch_redis_data(token)

    -- Initialize local values if not present
    if not local_sub_windows then
        local_sub_windows = {}
        for i = 1, number_of_sub_windows do
            local_sub_windows[i] = 0
        end
        shared_dict:set(sub_windows_key, cjson.encode(local_sub_windows))
    else
        local_sub_windows = cjson.decode(local_sub_windows)
    end

    if not last_access_time then
        last_access_time = now
        shared_dict:set(last_access_key, now)
    end

    if not batch_count then
        batch_count = 0
    end

    if not local_total_count then
        local_total_count = redis_total_count -- Initialize local total count from Redis
    end

    -- Calculate sliding window total (combined Redis and local values)
    local sliding_window_total = calculate_sliding_window_total(redis_sub_windows, local_sub_windows, now, last_access_time)

    -- Check if the total count exceeds the request limit
    if sliding_window_total >= request_limit then
        return false -- Deny request if rate limit exceeded
    end

    -- Increment batch count and subwindow count locally
    batch_count = batch_count + 1
    local current_sub_window_index = math.floor(now / sub_window_size) % number_of_sub_windows
    local_sub_windows[current_sub_window_index + 1] = local_sub_windows[current_sub_window_index + 1] + 1
    local_total_count = local_total_count + 1

    -- Update local shared memory with the new values
    shared_dict:set(sub_windows_key, cjson.encode(local_sub_windows))
    shared_dict:set(batch_count_key, batch_count)
    shared_dict:set(local_total_count_key, local_total_count)

    -- Sync with Redis if batch limit is reached
    if batch_count >= batch_size then
        local success = sync_with_redis(token, local_sub_windows, local_total_count, redis_sub_windows)
        if not success then
            return false -- Fail-safe if Redis sync fails
        end
    end

    return true -- Request allowed
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

-- Keep Redis connection alive
keep_redis_alive(red)
