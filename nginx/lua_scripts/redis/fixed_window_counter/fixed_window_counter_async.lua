local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Configuration
local redis_host = "redis"         -- Redis server host
local redis_port = 6379            -- Redis server port
local rate_limit = 500             -- Max requests allowed in the window
local batch_percent = 0.1          -- Percentage of remaining requests to allow in a batch
local min_batch_size = 1           -- Minimum size of batch
local window_size = 60             -- Time window size in seconds

-- Initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, "Failed to connect to Redis: " .. err
    end

    return red
end

-- Retrieve token from URL parameter
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Access Nginx shared dictionary
local function get_shared_dict()
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        return nil, "Failed to access shared dictionary"
    end
    return shared_dict
end

-- Calculate remaining TTL in the current window
local function calculate_ttl()
    local current_time = ngx.now()
    local window_start = math.floor(current_time / window_size) * window_size
    local ttl = window_size - (current_time - window_start)
    return math.max(1, math.ceil(ttl))  -- Ensure TTL is at least 1 second
end

-- Fetch batch quota from Redis
local function fetch_batch_quota(red, redis_key)
    local count, err = red:get(redis_key)
    if err then
        return nil, "Failed to GET from Redis: " .. err
    end

    count = tonumber(count) or 0
    local remaining = rate_limit - count

    if remaining <= 0 then
        return 0
    end

    local batch_size = math.floor(remaining * batch_percent)
    batch_size = math.max(batch_size, min_batch_size)
    batch_size = math.min(batch_size, remaining)

    return batch_size
end

-- Update Redis with the exhausted batch count and set TTL if necessary
local function update_redis(red, redis_key, batch_quota, ttl)
    local new_count, err = red:incrby(redis_key, batch_quota)
    if err then
        return nil, "Failed to INCRBY in Redis: " .. err
    end

    -- Set expiration if this is the first batch
    if new_count == batch_quota then
        red:expire(redis_key, ttl)
    end

    return true
end

-- Set new batch quota and reset used count in shared memory
local function set_new_batch(shared_dict, redis_key, batch_size, ttl)
    local ok, err = shared_dict:set(redis_key .. ":batch", batch_size, ttl)
    if not ok then
        return nil, "Failed to set batch quota in shared memory: " .. err
    end

    ok, err = shared_dict:set(redis_key .. ":used", 0, ttl)
    if not ok then
        return nil, "Failed to reset used count in shared memory: " .. err
    end

    return true
end

-- Process batch quota and update shared dictionary
local function process_batch_quota(red, shared_dict, redis_key, ttl)
    local batch_quota = shared_dict:get(redis_key .. ":batch") or 0
    local batch_used = shared_dict:get(redis_key .. ":used") or 0

    if batch_quota == 0 then
        local batch_size = fetch_batch_quota(red, redis_key)
        if not batch_size then
            return nil, "Failed to fetch batch quota"
        end

        if batch_size > 0 then
            local success, err = set_new_batch(shared_dict, redis_key, batch_size, ttl)
            if not success then
                return nil, err
            end

            return batch_size
        else
            -- No remaining requests
            return 0
        end
    end

    return batch_quota
end

-- Increment the used count and check if request is allowed
local function increment_and_check(shared_dict, redis_key, batch_quota, red, ttl)
    if batch_quota > 0 then
        local new_used, err = shared_dict:incr(redis_key .. ":used", 1, 0)
        if err then
            return nil, "Failed to increment used count: " .. err
        end

        if new_used <= batch_quota then
            return true  -- Request is allowed within batch quota
        else
            -- Batch exhausted; check global rate limit
            local current_count, err = red:get(redis_key)
            if err then
                return nil, "Failed to GET from Redis: " .. err
            end
            current_count = tonumber(current_count) or 0

            if current_count >= rate_limit then
                return false  -- Rate limit exceeded
            end

            -- Update Redis with the exhausted batch
            local success, err = update_redis(red, redis_key, batch_quota, ttl)
            if not success then
                return nil, err
            end

            -- Fetch new batch quota
            local new_batch_size = fetch_batch_quota(red, redis_key)
            if new_batch_size > 0 then
                -- Set new batch quota and reset used count
                local success, err = set_new_batch(shared_dict, redis_key, new_batch_size, ttl)
                if not success then
                    return nil, err
                end

                -- Increment used count for the current request
                local updated_used, err = shared_dict:incr(redis_key .. ":used", 1, 0)
                if not updated_used then
                    return nil, "Failed to increment used count after setting new batch: " .. err
                end

                return true  -- Request is allowed with new batch quota
            else
                return false  -- No new batch quota available, reject request
            end
        end
    end

    return false  -- No batch quota available, reject request
end

-- Main rate-limiting function
local function main()
    -- Initialize Redis
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Retrieve token
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Calculate TTL
    local ttl = calculate_ttl()

    -- Construct Redis key
    local window_start = math.floor(ngx.now() / window_size) * window_size
    local redis_key = string.format("rate_limit:%s:%d", token, window_start)

    -- Access shared dictionary
    local shared_dict, err = get_shared_dict()
    if not shared_dict then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Acquire lock to prevent race conditions
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(redis_key, { timeout = 10 })  -- 10 seconds timeout
    if not elapsed then
        ngx.log(ngx.ERR, "Failed to acquire lock: " .. err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Ensure lock is released on exit
    local function unlock_and_exit(status)
        local ok, err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "Failed to unlock: " .. err)
        end
        ngx.exit(status)
    end

    -- Process batch quota
    local batch_quota, err = process_batch_quota(red, shared_dict, redis_key, ttl)
    if not batch_quota then
        ngx.log(ngx.ERR, err)
        unlock_and_exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Determine if request is allowed
    local allowed, err = increment_and_check(shared_dict, redis_key, batch_quota, red, ttl)
    if err then
        ngx.log(ngx.ERR, err)
        unlock_and_exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Release the lock
    local ok, err = lock:unlock()
    if not ok then
        ngx.log(ngx.ERR, "Failed to unlock: " .. err)
    end

    -- Enforce rate limit
    if not allowed then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
end

-- Execute main function
main()
