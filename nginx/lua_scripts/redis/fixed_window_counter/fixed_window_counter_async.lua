local redis = require "resty.redis"
local resty_lock = require "resty.lock"

local redis_host = "redis"
local redis_port = 6379
local rate_limit = 500 -- 500 requests per minute
local window_size = 60 -- 60 second window
local batch_percent = 0.1 -- 10% of remaining quota
local min_batch_size = 1 -- Minimum batch size to use batching

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

-- Construct the Redis key using only the token
local redis_key = "rate_limit:" .. token

-- Initialize shared memory
local shared_dict = ngx.shared.rate_limit_dict
if not shared_dict then
    ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Function to fetch batch quota from Redis
local function fetch_batch_quota()
    -- Get current count and TTL
    -- Start a Redis transaction with MULTI
    local ok, err = red:multi()
    if not ok then
        ngx.log(ngx.ERR, "Failed to start Redis transaction: ", err)
        return nil, nil
    end

    -- Queue the GET and TTL commands
    red:get(redis_key)
    red:ttl(redis_key)

    -- Execute the transaction with EXEC
    local res, err = red:exec()
    if not res then
        ngx.log(ngx.ERR, "Failed to execute Redis transaction: ", err)
        return nil, nil
    end

    -- Extract the results
    local count = tonumber(res[1]) or 0  -- res[1] corresponds to GET result
    local ttl = tonumber(res[2]) or -2    -- res[2] corresponds to TTL result (-2 means the key doesn't exist)

    -- If key does not exist in Redis (TTL == -2), reset for a new window
    if ttl == -2 then
        ngx.log(ngx.DEBUG, "TTL expired, resetting counter for new window")
        count = 0
        ttl = window_size
        
        -- Reset the counter and set the expiration in a single Redis command
        local ok, err = red:set(redis_key, 0, "EX", window_size)
        if not ok then
            ngx.log(ngx.ERR, "Failed to reset counter and set expiration in Redis: ", err)
            return nil, nil
        end

    end

    count = tonumber(count) or 0
    ttl = tonumber(ttl) or 0
    
    -- Ensure ttl is non-negative
    ttl = math.max(0, ttl)
    
    -- Calculate remaining quota and batch size
    local remaining = math.max(0, rate_limit - count)
    if remaining == 0 then
        return 0, ttl  -- No more requests allowed in this window
    end
    
    local batch_size = math.floor(remaining * batch_percent)
    batch_size = math.max(math.min(batch_size, remaining), min_batch_size)
    
    -- We don't update Redis here anymore, we'll do it when the batch is exhausted
    
    return batch_size, ttl
end

-- Function to update Redis with the exhausted batch
local function update_redis_with_exhausted_batch(exhausted_batch_size)
    local new_count, err = red:incrby(redis_key, exhausted_batch_size)
    if err then
        ngx.log(ngx.ERR, "Failed to update counter in Redis with exhausted batch: ", err)
        return false
    end
    return true
end

-- Use a lock to ensure only one worker fetches the quota at a time
local lock = resty_lock:new("my_locks")
local elapsed, err = lock:lock(redis_key)
if not elapsed then
    ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Check if we need to fetch a new batch quota
local batch_quota, err = shared_dict:get(redis_key .. ":batch")
local batch_used, err_used = shared_dict:get(redis_key .. ":used")

if not batch_quota or batch_quota == 0 or not batch_used then
    -- Update Redis with the previously exhausted batch if it exists
    if batch_used and batch_used > 0 then
        local success = update_redis_with_exhausted_batch(batch_used)
        if not success then
            lock:unlock()
            ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
        end
    end
    
    -- Fetch new batch quota
    batch_quota, ttl = fetch_batch_quota()
    if batch_quota == nil then
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    
    if batch_quota > 0 then
        -- Store new batch quota in shared memory
        ok, err = shared_dict:set(redis_key .. ":batch", batch_quota, ttl)
        if not ok then
            ngx.log(ngx.ERR, "Failed to set batch quota in shared memory: ", err)
            lock:unlock()
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        -- Reset the used count for the new batch
        ok, err = shared_dict:set(redis_key .. ":used", 0, ttl)
        if not ok then
            ngx.log(ngx.ERR, "Failed to reset used count in shared memory: ", err)
            lock:unlock()
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    end
end

local allowed = false
if batch_quota > 0 then
    -- Increment the used count
    local new_used, err = shared_dict:incr(redis_key .. ":used", 1, 0)
    if err then
        ngx.log(ngx.ERR, "Failed to increment used count: ", err)
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    
    if new_used <= batch_quota then
        allowed = true
    else
        -- Batch is exhausted, update Redis and fetch a new batch
        local success = update_redis_with_exhausted_batch(batch_quota)
        if success then
            -- Fetch new batch quota
            batch_quota, ttl = fetch_batch_quota()
            if batch_quota and batch_quota > 0 then
                -- Store new batch quota in shared memory
                ok, err = shared_dict:set(redis_key .. ":batch", batch_quota, ttl)
                if not ok then
                    ngx.log(ngx.ERR, "Failed to set new batch quota in shared memory: ", err)
                    lock:unlock()
                    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
                end
                -- Reset the used count for the new batch
                ok, err = shared_dict:set(redis_key .. ":used", 1, ttl)
                if not ok then
                    ngx.log(ngx.ERR, "Failed to reset used count in shared memory: ", err)
                    lock:unlock()
                    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
                end
                allowed = true
            end
        end
    end
end

lock:unlock()

-- Check if the request should be allowed
if not allowed then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end
