-- Import the Redis client library
local redis = require "resty.redis"

-- Define the Redis host and port
local redis_host = "redis"
local redis_port = 6379

-- Connect to Redis
local red = redis:new()
red:set_timeout(1000) -- 1 second timeout

local ok, err = red:connect(redis_host, redis_port)
if not ok then
    ngx.say(ngx.ERR, "Failed to connect to Redis: ", err)
    return
end

-- Define the key prefix for rate limiting
local key_prefix = "rate_limit:"
-- Define the key for rate limiting (using the client's IP address)
local key = key_prefix .. ngx.var.remote_addr

-- Define the sliding window size in seconds
local window_size = 60  -- 1 minute window
-- Define the rate limit threshold
local rate_limit = 10

-- Get the current timestamp in seconds
local current_time = ngx.now()

-- Calculate the start and end of the sliding window for the current minute
local window_start_current = math.floor(current_time / 60) * 60
local window_end_current = window_start_current + window_size

-- Calculate the start and end of the sliding window for the previous minute
local window_start_previous = window_start_current - window_size
local window_end_previous = window_start_current

-- Retrieve the counts from Redis for the current and previous minutes
local counts_current, err_current = red:zrangebyscore(key, window_start_current, window_end_current, "WITHSCORES")
local counts_previous, err_previous = red:zrangebyscore(key, window_start_previous, window_end_previous, "WITHSCORES")

if err_current or err_previous then
    ngx.say(ngx.ERR, "Failed to get counts from Redis: ", err_current or err_previous)
    return
end

-- Count the number of requests within the current and previous minutes
local request_count_current = counts_current and #counts_current / 2 or 0
local request_count_previous = counts_previous and #counts_previous / 2 or 0

-- Calculate the sliding window factor
local sliding_factor = request_count_current + request_count_previous

-- Increment the count for the current request
red:zadd(key, current_time, current_time)
red:expire(key, window_size)  -- Set expiration for the key

-- Check if the sliding window factor exceeds the rate limit
if sliding_factor > rate_limit then
    ngx.exit(ngx.HTTP_FORBIDDEN)
else
    ngx.say("Rate available")
end
