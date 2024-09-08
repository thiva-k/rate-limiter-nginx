local redis = require "resty.redis"

local redis_host = "redis"
local redis_port = 6379

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

-- Hardcoded rate limit and window size
local rate_limit = 500 -- 100 requests per minute
local window_size = 60 -- 1 minute window

-- Construct the Redis key using the token
local key = "rate_limit:" .. token

-- Get the current timestamp
local current_time = ngx.now()

-- Remove old entries and add the new one atomically
local redis_script = [[
    local key = KEYS[1]
    local now = tonumber(ARGV[1])
    local window = tonumber(ARGV[2])
    local limit = tonumber(ARGV[3])

    -- Remove elements outside the current window
    redis.call('ZREMRANGEBYSCORE', key, 0, now - window)

    -- Count the number of elements in the current window
    local count = redis.call('ZCARD', key)

    -- If under the limit, add the new element
    if count < limit then
        redis.call('ZADD', key, now, now)
        redis.call('EXPIRE', key, window)
        return 0
    else
        return 1
    end
]]

local sha
sha, err = red:script("LOAD", redis_script)
if err then
    ngx.log(ngx.ERR, "Failed to load Redis script: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local result
result, err = red:evalsha(sha, 1, key, current_time, window_size, rate_limit)
if err then
    ngx.log(ngx.ERR, "Failed to execute Redis script: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

if result == 1 then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Request is allowed, continue processing