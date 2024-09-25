local redis = require "resty.redis"

local redis_host = "redis"
local redis_port = 6379

local red = redis:new()
red:set_timeout(1000) -- 1 second timeout

local ok, err = red:connect(redis_host, redis_port)
if not ok then
    ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR) -- 500
end

-- Fetch the token from the URL parameter
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST) -- 400
end

local bucket_capacity = 10 -- Maximum number of tokens in the bucket
local refill_rate = 1 -- Rate of token generation (tokens/second)
local now = ngx.now() * 1000 -- Current timestamp in milliseconds
local requested = 1 -- Number of tokens requested for the operation
local ttl = 60 -- Time-to-live for the token bucket state
local lock_key = token .. ":lock"
local lock_ttl = 1000 -- Lock expiration time in milliseconds
local retry_delay = 100 -- Delay between retries in milliseconds

-- Function to acquire the lock with retries
local function acquire_lock()
    local lock_value = ngx.time() .. ":" .. ngx.worker.pid()
    while true do
        local ok, err = red:set(lock_key, lock_value, "NX", "PX", lock_ttl)
        if ok == ngx.null then
            ngx.log(ngx.ERR, "Failed to acquire lock, retrying: ", err)
            ngx.sleep(retry_delay / 1000) -- Convert milliseconds to seconds
        else 
            return lock_value
        end
    end
end

-- Acquire the lock
local lock_value = acquire_lock()

-- Define keys for the token counter and last access time
local tokens_key = token .. ":tokens"
local last_access_key = token .. ":last_access"

-- Fetch the current token count
local last_tokens = tonumber(red:get(tokens_key))
if last_tokens == nil then
    last_tokens = bucket_capacity
end

-- Fetch the last access time
local last_access = tonumber(red:get(last_access_key))
if last_access == nil then
    -- Initialize to current time if not found in Redis
    last_access = now
end

ngx.log(ngx.ERR, "last_tokens: ", last_tokens, " last_access: ", last_access)

-- Calculate the number of tokens to be added due to the elapsed time since the last access
local elapsed = math.max(0, now - last_access)
local add_tokens = math.floor(elapsed * refill_rate / 1000)
local new_tokens = math.min(bucket_capacity, last_tokens + add_tokens)

-- Check if enough tokens have been accumulated
local allowed = new_tokens >= requested
if allowed then
    new_tokens = new_tokens - requested
    last_access = now
    -- Update state in Redis
    red:set(tokens_key, new_tokens, "EX", ttl)
    red:set(last_access_key, last_access, "EX", ttl)
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429
end

-- Release the lock
local current_lock_value = red:get(lock_key)
if current_lock_value == lock_value then
    red:del(lock_key)
else
    ngx.log(ngx.ERR, "Lock value mismatch, not releasing lock")
end

-- TODO: have to update current time at the time of updating it to database or have to use redis time command