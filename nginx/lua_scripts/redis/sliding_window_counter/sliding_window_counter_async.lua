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

-- Construct the Redis key using the token
local redis_key = "rate_limit:" .. token

-- Initialize shared memory
local shared_dict = ngx.shared.rate_limit_dict
if not shared_dict then
    ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Function to fetch batch quota from Redis
local function fetch_batch_quota()
    local current_time = ngx.now() * 1000 -- Current time in milliseconds

    -- Fetch the timestamps of the requests in the last window
    local res, err = red:zrangebyscore(redis_key, current_time - (window_size * 1000), current_time)
    if not res then
        ngx.log(ngx.ERR, "Failed to fetch timestamps from Redis: ", err)
        return nil, nil
    end

    local request_count = #res -- Count the number of requests in the sliding window

    -- If there are no requests, reset the counter
    if request_count == 0 then
        ngx.log(ngx.DEBUG, "No recent requests, resetting quota")
        request_count = 0
    end

    -- Calculate remaining quota and batch size
    local remaining = math.max(0, rate_limit - request_count)
    if remaining == 0 then
        return 0, window_size -- No more requests allowed in this window
    end

    local batch_size = math.floor(remaining * batch_percent)
    batch_size = math.max(math.min(batch_size, remaining), min_batch_size)

    return batch_size, window_size
end

-- Function to update Redis with the exhausted batch
local function update_redis_with_exhausted_batch(exhausted_batch_size)
    local current_time = ngx.now() * 1000 -- Current time in milliseconds

    -- Add the exhausted batch size (timestamps) to the sorted set in Redis
    for i = 1, exhausted_batch_size do
        local ok, err = red:zadd(redis_key, current_time + i, current_time + i)
        if not ok then
            ngx.log(ngx.ERR, "Failed to update counter in Redis with exhausted batch: ", err)
            return false
        end
    end

    -- Optionally set an expiration time on the Redis key
    local ok, err = red:expire(redis_key, window_size)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set expiration on Redis key: ", err)
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
