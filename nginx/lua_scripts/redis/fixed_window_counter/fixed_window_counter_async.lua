local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Global variables
local redis_host = "redis"
local redis_port = 6379
local rate_limit = 500 -- 500 requests per minute
local window_size = 60 -- 60 second window
local batch_percent = 0.1 -- 10% of remaining quota
local min_batch_size = 1 -- Minimum batch size to use batching

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

-- Get token from URL parameter
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Initialize shared dictionary
local function init_shared_dict()
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        return nil, "Failed to initialize shared dictionary"
    end
    return shared_dict
end

-- Fetch batch quota from Redis
local function fetch_batch_quota(red, redis_key)
    -- Start a Redis transaction
    local ok, err = red:multi()
    if not ok then
        return nil, "Failed to start Redis transaction: " .. err
    end

    -- Queue GET and TTL commands
    red:get(redis_key)
    red:ttl(redis_key)

    -- Execute the transaction
    local res, err = red:exec()
    if not res then
        return nil, "Failed to execute Redis transaction: " .. err
    end

    local count = tonumber(res[1]) or 0
    local ttl = tonumber(res[2]) or -2

    -- If key does not exist in Redis, reset for a new window
    if ttl == -2 then
        count = 0
        ttl = window_size
        
        local ok, err = red:set(redis_key, 0, "EX", window_size)
        if not ok then
            return nil, "Failed to reset counter and set expiration in Redis: " .. err
        end
    end

    count = tonumber(count) or 0
    ttl = math.max(0, tonumber(ttl) or 0)
    
    -- Calculate remaining quota and batch size
    local remaining = math.max(0, rate_limit - count)
    if remaining == 0 then
        return 0, ttl  -- No more requests allowed in this window
    end
    
    local batch_size = math.floor(remaining * batch_percent)
    batch_size = math.max(math.min(batch_size, remaining), min_batch_size)
    
    return batch_size, ttl
end

-- Update Redis with the exhausted batch
local function update_redis_with_exhausted_batch(red, redis_key, exhausted_batch_size)
    local new_count, err = red:incrby(redis_key, exhausted_batch_size)
    if err then
        return nil, "Failed to update counter in Redis with exhausted batch: " .. err
    end
    return true
end

-- Process batch quota
local function process_batch_quota(red, shared_dict, redis_key, lock)
    local batch_quota, err = shared_dict:get(redis_key .. ":batch")
    local batch_used, err_used = shared_dict:get(redis_key .. ":used")

    -- Check if we need to fetch a new batch quota
    if not batch_quota or batch_quota == 0 or not batch_used then
        -- Update Redis with the previously exhausted batch if it exists
        if batch_used and batch_used > 0 then
            local success, err = update_redis_with_exhausted_batch(red, redis_key, batch_used)
            if not success then
                return nil, err
            end
        end
        
        -- Fetch new batch quota
        local ttl
        batch_quota, ttl = fetch_batch_quota(red, redis_key)
        if batch_quota == nil then
            return nil, "Failed to fetch batch quota"
        end
        
        if batch_quota > 0 then
            -- Store new batch quota in shared memory
            local ok, err = shared_dict:set(redis_key .. ":batch", batch_quota, ttl)
            if not ok then
                return nil, "Failed to set batch quota in shared memory: " .. err
            end
            -- Reset the used count for the new batch
            ok, err = shared_dict:set(redis_key .. ":used", 0, ttl)
            if not ok then
                return nil, "Failed to reset used count in shared memory: " .. err
            end
        end
    end

    return batch_quota
end

-- Increment the used count and check if request is allowed
local function increment_and_check(shared_dict, redis_key, batch_quota, red)
    if batch_quota > 0 then
        -- Increment the used count
        local new_used, err = shared_dict:incr(redis_key .. ":used", 1, 0)
        if err then
            return nil, "Failed to increment used count: " .. err
        end
        
        if new_used <= batch_quota then
            return true  -- Request is allowed
        else
            -- Batch is exhausted, update Redis and fetch a new batch
            local success, err = update_redis_with_exhausted_batch(red, redis_key, batch_quota)
            if success then
                -- Fetch new batch quota
                local ttl
                batch_quota, ttl = fetch_batch_quota(red, redis_key)
                if batch_quota and batch_quota > 0 then
                    -- Store new batch quota in shared memory
                    local ok, err = shared_dict:set(redis_key .. ":batch", batch_quota, ttl)
                    if not ok then
                        return nil, "Failed to set new batch quota in shared memory: " .. err
                    end
                    -- Reset the used count for the new batch
                    ok, err = shared_dict:set(redis_key .. ":used", 1, ttl)
                    if not ok then
                        return nil, "Failed to reset used count in shared memory: " .. err
                    end
                    return true  -- Request is allowed
                end
            else
                return nil, err
            end
        end
    end
    return false  -- Request is not allowed
end

-- Main function to orchestrate the rate limiting process
local function main()
    -- Initialize Redis
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Get token from URL parameter
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Construct the Redis key using the token
    local redis_key = "rate_limit:" .. token

    -- Initialize shared dictionary
    local shared_dict, err = init_shared_dict()
    if not shared_dict then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Use a lock with TTL to ensure only one worker fetches the quota at a time
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(redis_key, { timeout = 10 })  -- 10 seconds TTL
    if not elapsed then
        ngx.log(ngx.ERR, "Failed to acquire lock: " .. err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Process batch quota
    local batch_quota, err = process_batch_quota(red, shared_dict, redis_key, lock)
    if not batch_quota then
        ngx.log(ngx.ERR, err)
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Check if the request should be allowed
    local allowed, err = increment_and_check(shared_dict, redis_key, batch_quota, red)
    if err then
        ngx.log(ngx.ERR, err)
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Release the lock
    local ok, err = lock:unlock()
    if not ok then
        ngx.log(ngx.ERR, "Failed to unlock: " .. err)
    end

    -- If not allowed, return 429 Too Many Requests
    if not allowed then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
end

-- Execute main function
main()