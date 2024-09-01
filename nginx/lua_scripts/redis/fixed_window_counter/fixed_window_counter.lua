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

local rate_limit = 5 -- 50 requests per minute
local window_size = 60 -- 60 second window

-- Construct the Redis key using only the token
local redis_key = "rate_limit:" .. token

-- Increment the counter
local count, err = red:incr(redis_key)
if err then
    ngx.log(ngx.ERR, "Failed to increment counter in Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Check if the number of requests exceeds the rate limit
if tonumber(count) > rate_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Set the expiration time for the Redis key if it's a new key
if tonumber(count) == 1 then
    local ok, err = red:expire(redis_key, window_size)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set expiration for key in Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
end