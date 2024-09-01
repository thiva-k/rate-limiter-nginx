local redis = require "resty.redis"
local cjson = require "cjson"

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
local timestamps_key = "rate_limit:" .. token

-- Fetch the timestamps of the requests for this token
local timestamps_json, err = red:get(timestamps_key)
if err then
    ngx.log(ngx.ERR, "Failed to get request timestamps from Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local timestamps = {}
if timestamps_json and timestamps_json ~= ngx.null then
    timestamps = cjson.decode(timestamps_json)
end

local current_time = ngx.now()

-- Remove timestamps outside the current window
local new_timestamps = {}
for _, timestamp in ipairs(timestamps) do
    if current_time - tonumber(timestamp) < window_size then
        table.insert(new_timestamps, timestamp)
    end
end

-- Add the current request timestamp
table.insert(new_timestamps, current_time)

-- Check if the number of requests exceeds the rate limit
if #new_timestamps > rate_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Save the updated timestamps back to Redis
local new_timestamps_json = cjson.encode(new_timestamps)
local _, err = red:set(timestamps_key, new_timestamps_json)
if err then
    ngx.log(ngx.ERR, "Failed to set request timestamps in Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Set the expiration time for the token key in Redis (window size + buffer)
local _, err = red:expire(timestamps_key, window_size + 10)
if err then
    ngx.log(ngx.ERR, "Failed to set expiration for rate key in Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end