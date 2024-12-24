local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local rate_limit = 19 -- 10 requests per minute
local window_size = 60 -- 60 second window
local batch_percent = 0.5 -- 10% of remaining quota for static allocation
local max_percent_remaining = 0.6 -- 50% of remaining quota for dynamic allocation
local min_batch_size = 1 -- Minimum batch size to use batching

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

-- Function to count requests in previous window from local timestamps
local function count_previous_window_requests(shared_dict, redis_key)
    local current_time = ngx.now()
    local previous_window_start = current_time - (window_size)
    local previous_window_end = current_time
    
    local count = 0
    local timestamps_len = shared_dict:llen(redis_key .. ":timestamps")
    
    if timestamps_len > 0 then
        for i = 1, timestamps_len do
            -- Use lindex to read timestamp without removing it
            local ts = shared_dict:lindex(redis_key .. ":timestamps", i-1)  -- lindex is 0-based
            if ts and ts >= previous_window_start and ts < previous_window_end then
                count = count + 1
            end
        end
    end
    
    return count
end

-- Function to fetch batch quota from Redis with dynamic calculation
local function fetch_batch_quota(red, redis_key, shared_dict, dynamic)
    local current_time = ngx.now()
    local window_start = current_time - window_size

    -- Start a Redis transaction
    local ok, err = red:multi()
    if not ok then
        return nil, "Failed to start Redis transaction: " .. err
    end

    -- Queue commands in the transaction
    red:zremrangebyscore(redis_key, 0, window_start)
    red:zcard(redis_key)

    -- Execute the transaction
    local results, err = red:exec()
    if not results then
        return nil, "Failed to execute Redis transaction: " .. err
    end

    -- Parse the results
    local removed = results[1]
    local count = results[2]

    -- Calculate remaining quota
    local remaining = math.max(0, rate_limit - count)
    if remaining == 0 then
        return 0, window_size  -- No more requests allowed in this window
    end

    -- Get previous window request count if dynamic is enabled
    local previous_window = 0
    if dynamic then
        previous_window = count_previous_window_requests(shared_dict, redis_key)
    end

    -- Calculate batch quota based on dynamic or static approach
    local batch_size
    if dynamic and previous_window > 0 then
        local calculated_quota = math.ceil(remaining * max_percent_remaining)
        batch_size = math.min(previous_window, calculated_quota)
    else
        batch_size = math.ceil(remaining * batch_percent)
    end

    return batch_size, window_size
end

-- Function to update Redis with the exhausted batch
local function update_redis_with_exhausted_batch(red, shared_dict, redis_key)
    local multi_result, err = red:multi()
    if not multi_result then
        return false, "Failed to start Redis transaction: " .. err
    end

    local timestamps_len = shared_dict:llen(redis_key .. ":timestamps")
    for i = 1, timestamps_len do
        local ts, err = shared_dict:lpop(redis_key .. ":timestamps")
        if ts then
            red:zadd(redis_key, ts, ts)
        else
            red:discard()
            return false, "Failed to pop timestamp from shared dict: " .. err
        end
    end

    local exec_result, err = red:exec()
    if not exec_result then
        return false, "Failed to execute Redis transaction: " .. err
    end

    return true
end

-- Function to handle batch quota and timestamps
local function process_batch_quota(shared_dict, redis_key, red, dynamic)
    local batch_quota = shared_dict:get(redis_key .. ":batch")
    local timestamps_len = shared_dict:llen(redis_key .. ":timestamps")

    if not batch_quota or batch_quota == 0 or not timestamps_len then
        -- Update Redis with the previously exhausted batch if it exists
        if timestamps_len and timestamps_len > 0 then
            local success, err = update_redis_with_exhausted_batch(red, shared_dict, redis_key)
            if not success then
                return nil, err
            end
        end

        -- Fetch new batch quota
        local new_quota, ttl = fetch_batch_quota(red, redis_key, shared_dict, dynamic)
        if new_quota == nil then
            return nil, ttl  -- ttl contains error message in this case
        end

        if new_quota > 0 then
            -- Store new batch quota in shared memory
            local ok, err = shared_dict:set(redis_key .. ":batch", new_quota, ttl)
            if not ok then
                return nil, "Failed to set batch quota in shared memory: " .. err
            end
            batch_quota = new_quota
        else
            batch_quota = 0
        end
    end

    return batch_quota, timestamps_len
end

-- Function to process the request
local function increment_and_check(shared_dict, redis_key, red, batch_quota, dynamic)
    if batch_quota <= 0 then
        return false
    end

    -- Add current timestamp to the batch
    local current_time = ngx.now()
    local length, err = shared_dict:rpush(redis_key .. ":timestamps", current_time)
    if not length then
        return nil, "Failed to update timestamps in shared memory: " .. err
    end
    
    -- Decrement the batch quota
    local new_quota, err = shared_dict:incr(redis_key .. ":batch", -1, 0)
    if err then
        return nil, "Failed to decrement batch quota: " .. err
    end
    
    return true
    
end

-- Main rate limiting logic
local function check_rate_limit(red, token, shared_dict, dynamic)
    local redis_key = "rate_limit:" .. token

    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(redis_key)
    if not elapsed then
        return nil, "Failed to acquire lock: " .. err
    end

    -- Ensure lock is always released
    local function cleanup(err)
        local ok, unlock_err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "Failed to release lock: ", unlock_err)
        end
        if err then
            return nil, err
        end
        return true
    end

    local batch_quota, timestamps_count = process_batch_quota(shared_dict, redis_key, red, dynamic)
    if not batch_quota then
        return cleanup("Failed to handle batch quota: " .. timestamps_count)
    end

    local allowed, err = increment_and_check(shared_dict, redis_key, red, batch_quota, dynamic)
    if err then
        return cleanup("Failed to process request: " .. err)
    end

    if not allowed then
        cleanup()
        return ngx.HTTP_TOO_MANY_REQUESTS
    end

    cleanup()
    return ngx.HTTP_OK
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    -- Get token from URL parameters
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

    -- Get shared dictionary
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Run rate limiting check with error handling
    local dynamic = true  -- Set to false for static batch quota calculation
    local res, status = pcall(check_rate_limit, red, token, shared_dict, dynamic)
    
    -- Properly close Redis connection
    local ok, close_err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", close_err)
    end

    -- Handle any errors from the rate limiting check
    if not res then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif status == ngx.HTTP_TOO_MANY_REQUESTS then
        ngx.exit(status)
    end
end

-- Run the main function
main()