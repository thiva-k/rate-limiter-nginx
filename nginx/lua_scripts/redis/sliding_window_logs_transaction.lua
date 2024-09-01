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

local current_time = ngx.now()

-- Lua script
local script = [[
-- ARGV[1] = token
-- ARGV[2] = rate_limit
-- ARGV[3] = window_size
-- ARGV[4] = current_time

local token = ARGV[1]
local rate_limit = tonumber(ARGV[2])
local window_size = tonumber(ARGV[3])
local current_time = tonumber(ARGV[4])

local timestamps_key = "rate_limit:" .. token
local timestamps_json = redis.call("GET", timestamps_key)
local timestamps = cjson.decode(timestamps_json or "[]")

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
    return { err = "Too Many Requests" }
end

-- Save the updated timestamps back to Redis
redis.call("SET", timestamps_key, cjson.encode(new_timestamps))
redis.call("EXPIRE", timestamps_key, window_size + 10)

return { ok = "Request allowed" }
]]

-- Execute the Lua script
local res, err = red:eval(script, 0, token, rate_limit, window_size, current_time)
if not res then
    ngx.log(ngx.ERR, "Failed to execute Lua script: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

if res[1] == "Too Many Requests" then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end