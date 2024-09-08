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
local rate_limit = 100 -- 100 requests per minute
local window_size = 60 -- 1 minute window

-- Construct the Redis key using the token
local key = "rate_limit:" .. token

-- Get the current timestamp
local current_time = ngx.now()

-- Start a Redis transaction
red:multi()

-- Remove elements outside the current window
red:zremrangebyscore(key, 0, current_time - window_size)

-- Count the number of elements in the current window
red:zcard(key)

-- Execute the transaction
local results, err = red:exec()
if not results then
    ngx.log(ngx.ERR, "Failed to execute Redis transaction: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Check the results
local removed = results[1]
local count = results[2]

-- Check if the number of requests exceeds the rate limit
if count >= rate_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- If we're here, we're under the limit. Now we can add the new element and set expiration atomically
red:multi()
red:zadd(key, current_time, current_time)
red:expire(key, window_size)
results, err = red:exec()

if not results then
    ngx.log(ngx.ERR, "Failed to execute Redis transaction: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Request is allowed, continue processing