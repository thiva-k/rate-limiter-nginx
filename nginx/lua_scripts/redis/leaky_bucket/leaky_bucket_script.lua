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
local now = ngx.now() * 1000 -- Current timestamp in milliseconds
local requested = 1 -- Number of tokens requested for the operation
local ttl = 60 -- Time-to-live for the bucket state in Redis

-- Define keys for the token counter and last leak time
local tokens_key = token .. ":tokens"
local last_access_key = token .. ":last_access"

-- Lua script for atomic leaky bucket operation
local script = [[
    local tokens_key = KEYS[1]
    local last_access_key = KEYS[2]
    local bucket_capacity = tonumber(ARGV[1])
    local leak_rate = tonumber(ARGV[2])
    local now = tonumber(ARGV[3])
    local requested = tonumber(ARGV[4])
    local ttl = tonumber(ARGV[5])

    -- Fetch the current token count (if not found, assume 0)
    local last_tokens = tonumber(redis.call("get", tokens_key)) or 0

    -- Fetch the last leak time (if not found, initialize to now)
    local last_access = tonumber(redis.call("get", last_access_key)) or now

    -- Calculate the number of leaked tokens since the last access
    local elapsed = math.max(0, now - last_access)
    local leaked_tokens = math.floor(elapsed * leak_rate / 1000)
    local bucket_level = math.max(0, last_tokens - leaked_tokens)

    -- Check if we can add more tokens to the bucket
    if bucket_level < bucket_capacity then
        -- Update the bucket level with the requested number of tokens
        bucket_level = bucket_level + requested
        -- Update Redis with the new state
        redis.call("set", tokens_key, bucket_level, "EX", ttl)
        redis.call("set", last_access_key, now, "EX", ttl)
        return 1 -- Allowed
    else
        return 0 -- Not allowed (429)
    end
]]

-- Execute the Lua script atomically
local result, err = red:eval(script, 2, tokens_key, last_access_key, bucket_capacity, leak_rate, now, requested, ttl)
if result == 1 then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429
end

-- TODO: have to update current time at the time of updating it to database or have to use redis time command