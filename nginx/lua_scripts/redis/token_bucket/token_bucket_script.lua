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

local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST) -- 400
end

local bucket_capacity = 10
local refill_rate = 1 -- tokens/second
local ttl = 60 -- seconds
local now = ngx.now() * 1000 -- Current time in milliseconds
local requested = 1 -- tokens required per request

local tokens_key = token .. ":tokens"
local last_access_key = token .. ":last_access"

-- Lua script for token bucket logic
local script = [[
    local tokens_key = KEYS[1]
    local last_access_key = KEYS[2]
    local bucket_capacity = tonumber(ARGV[1])
    local refill_rate = tonumber(ARGV[2])
    local now = tonumber(ARGV[3])
    local requested = tonumber(ARGV[4])
    local ttl = tonumber(ARGV[5])

    local last_tokens = tonumber(redis.call("get", tokens_key)) or bucket_capacity
    local last_access = tonumber(redis.call("get", last_access_key)) or now

    local elapsed = math.max(0, now - last_access)
    local add_tokens = math.floor(elapsed * refill_rate / 1000)
    local new_tokens = math.min(bucket_capacity, last_tokens + add_tokens)

    if new_tokens >= requested then
        new_tokens = new_tokens - requested
        redis.call("set", tokens_key, new_tokens, "EX", ttl)
        redis.call("set", last_access_key, now, "EX", ttl)
        return 1
    else
        return 0
    end
]]

-- Execute the Lua script atomically
local result, err = red:eval(script, 2, tokens_key, last_access_key, bucket_capacity, refill_rate, now, requested, ttl)
if result == 1 then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429
end
