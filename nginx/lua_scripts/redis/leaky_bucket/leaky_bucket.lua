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
local leak_rate = 1 -- Rate of token leakage (tokens/second)
local now = ngx.now() * 1000000 -- Current timestamp in microseconds
local requested = 1 -- Number of tokens requested for the operation
local ttl = 60 -- Time-to-live for the bucket state

-- Define keys for the token counter and last leak time
local tokens_key = token .. ":tokens"
local last_access_key = token .. ":last_access"

-- Fetch the current token count
local last_tokens = tonumber(red:get(tokens_key))
if last_tokens == nil then
    last_tokens = 0
end

-- Fetch the last leak time
local last_access = tonumber(red:get(last_access_key))
if last_access == nil then
    -- Initialize to current time if not found in Redis
    last_access = now
end

-- Calculate the number of tokens that have leaked due to the elapsed time since the last leak
local elapsed = math.max(0, now - last_access)
local leaked_tokens = math.floor(elapsed * leak_rate / 1000000)
local bucket_level = math.max(0, last_tokens - leaked_tokens)
ngx.log(ngx.ERR, "elapsed: ", elapsed, " leaked_tokens: ", leaked_tokens, " bucket_level: ", bucket_level)

-- Check if current token level less than capacity
local allowed = bucket_level < bucket_capacity
if allowed then
    bucket_level = bucket_level + requested
    last_access = now
end

-- Update state in Redis
red:set(tokens_key, bucket_level, "EX", ttl)
red:set(last_access_key, last_access, "EX", ttl)

if allowed then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429
end