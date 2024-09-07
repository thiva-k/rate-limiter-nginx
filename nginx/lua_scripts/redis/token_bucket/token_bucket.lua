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

local capacity = 10 -- Maximum number of tokens in the bucket
local rate = 1 -- Rate of token generation (tokens/second)
local now = ngx.now() * 1000000 -- Current timestamp in microseconds
local requested = 1 -- Number of tokens requested for the operation

-- Define keys for the token counter and last access time
local tokens_key = token .. ":tokens"
local last_access_key = token .. ":last_access"

-- Fetch the current token count
local last_tokens = tonumber(red:get(tokens_key))
if last_tokens == ngx.null or last_tokens == nil then
    last_tokens = capacity
end

-- Fetch the last access time
local last_access = tonumber(red:get(last_access_key))
if last_access == ngx.null or last_access == nil then
    -- Initialize to current time if not found in Redis
    last_access = now
end

-- Calculate the number of tokens to be added due to the elapsed time since the last access
local elapsed = math.max(0, now - last_access)
local add_tokens = math.floor(elapsed * rate / 1000000)
local new_tokens = math.min(capacity, last_tokens + add_tokens)

-- Calculate the new last access time
local new_access_time = now -- Update to current time

-- Check if enough tokens have been accumulated
local allowed = new_tokens >= requested
if allowed then
    new_tokens = new_tokens - requested
end

-- Update state in Redis
red:setex(tokens_key, 60, new_tokens)
red:setex(last_access_key, 60, new_access_time)

-- Return 1 if the operation is allowed, 0 otherwise
if allowed then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429
end