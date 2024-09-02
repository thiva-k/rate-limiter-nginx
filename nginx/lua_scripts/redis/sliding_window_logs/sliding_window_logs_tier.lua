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

local token_param_name = "token" -- Name of the URL parameter containing the token
local rate_limit_field = "rate_limit"

-- Fetch the token from the URL parameter
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

-- Fetch the API endpoint from the nginx variable
local api = ngx.var.endpoint or "api1" -- Default API if not provided

-- Construct the Redis key using the token
local token_tier_mapping_key = "token_tier_mapping"
local tier_key_prefix = "tiers:"
local default_tier = "free"  -- Default tier if token not found in mapping

-- Fetch the tier of the token from Redis
local tier, err = red:hget(token_tier_mapping_key, token)
if err then
    ngx.log(ngx.ERR, "Failed to get tier from Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

if tier == ngx.null then
    ngx.log(ngx.ERR, "Token tier not found, using default tier")
    tier = default_tier
end

-- Construct the Redis key using the tier and API for rate limit
local rate_limit_key = tier .. ":" .. rate_limit_field .. ":" .. api

-- Fetch the specific rate limit for this tier and API from Redis
local rate_limit, err = red:hget("tiers", rate_limit_key)
if err then
    ngx.log(ngx.ERR, "Failed to get rate limit from Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

if rate_limit == ngx.null then
    rate_limit = 10 -- Default rate limit if not found in Redis
else
    rate_limit = tonumber(rate_limit)
end

-- Construct the Redis key using the tier and API for throttle limit
local throttle_limit_key = tier .. ":throttle_limit:" .. api

-- Fetch the specific throttle limit for this tier and API from Redis
local throttle_limit, err = red:hget("tiers", throttle_limit_key)
if err then
    ngx.log(ngx.ERR, "Failed to get throttle limit from Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

if throttle_limit == ngx.null then
    throttle_limit = 1000 -- Default throttle limit if not found in Redis
else
    throttle_limit = tonumber(throttle_limit)
end

-- Fetch the timestamps of the requests for this token
local rate_timestamps_field = "rate_timestamps:" .. api
local timestamps_key = "token:" .. token
local timestamps_json, err = red:hget(timestamps_key, rate_timestamps_field)
if err then
    ngx.log(ngx.ERR, "Failed to get request timestamps from Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local timestamps = {}
if timestamps_json ~= ngx.null then
    timestamps = cjson.decode(timestamps_json)
end

local current_time = ngx.now()
local window_size = 60 -- 1 minute window

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
local _, err = red:hset(timestamps_key, rate_timestamps_field, new_timestamps_json)
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

-- Throttling Check
local throttle_count_prefix = "throttle_count:"  -- Prefix for throttle count field in Redis
local throttle_count_field = throttle_count_prefix .. api
local throttle_count_key = "token:" .. token

-- Fetch the current throttle count from Redis
local throttle_count, err = red:hget(throttle_count_key, throttle_count_field)
if err then
    ngx.log(ngx.ERR, "Failed to get throttle count from Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

throttle_count = tonumber(throttle_count) or 0  -- Convert to number or default to 0

-- Check if the throttle limit is reached
if throttle_count >= throttle_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Increment the throttle count
throttle_count = throttle_count + 1

-- Update throttle count in Redis
local _, err = red:hset(throttle_count_key, throttle_count_field, throttle_count)
if err then
    ngx.log(ngx.ERR, "Failed to set throttle count in Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Set the expiration time for the throttle count key in Redis (One monnth)
local _, err = red:expire(throttle_count_key, 30 * 24 * 60 * 60)
if err then
    ngx.log(ngx.ERR, "Failed to set expiration for throttle count key in Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
