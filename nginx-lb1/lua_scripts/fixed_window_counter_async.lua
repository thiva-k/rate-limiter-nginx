local redis = require "resty.redis"
local resty_lock = require "resty.lock"

local redis_host = "redis"
local redis_port = 6379
local rate_limit = 500 -- 5000 requests per minute
local window_size = 60 -- 60 second window
local batch_percent = 0.1 -- 10% of remaining quota

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
    local count, err = red:get(redis_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get counter from Redis: ", err)
        return nil
    end
    
    local ttl, err = red:ttl(redis_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get TTL from Redis: ", err)
        return nil
    end
    
    count = tonumber(count) or 0
    ttl = tonumber(ttl) or 0
    
    -- Calculate remaining quota and batch size
    local remaining = math.max(0, rate_limit - count)
    local batch_size = math.floor(remaining * batch_percent)
    
    -- Store batch quota in shared memory
    ok, err = shared_dict:set(redis_key, batch_size, ttl)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set batch quota in shared memory: ", err)
        return nil
    end
    
    -- Update Redis counter
    red:incrby(redis_key, batch_size)
    
    return batch_size, ttl
end

-- Use a lock to ensure only one worker fetches the quota at a time
local lock = resty_lock:new("my_locks")
local elapsed, err = lock:lock(redis_key)
if not elapsed then
    ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Check if we need to fetch a new batch quota
local batch_quota, err = shared_dict:get(redis_key)
if not batch_quota or batch_quota == 0 then
    batch_quota, ttl = fetch_batch_quota()
    if not batch_quota then
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
end

-- Decrement the batch quota
local new_quota, err = shared_dict:incr(redis_key, -1)
if err then
    ngx.log(ngx.ERR, "Failed to decrement batch quota: ", err)
    lock:unlock()
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

lock:unlock()

-- Check if the request should be allowed
if new_quota < 0 then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- If this is the first request, set the expiration time for the Redis key
if new_quota == rate_limit - 1 then
    local ok, err = red:expire(redis_key, window_size)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set expiration for key in Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
end