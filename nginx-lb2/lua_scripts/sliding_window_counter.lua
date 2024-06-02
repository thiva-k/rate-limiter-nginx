local upstream_servers = { "server3:8080", "server4:8080" }
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

local ip_key = ngx.var.remote_addr
local rate_limit_field = "rate_limit"
local rate_timestamps_field = "rate_timestamps"

-- Fetch the specific rate limit for this IP address from Redis
local rate_limit, err = red:hget(ip_key, rate_limit_field)
if err then
    ngx.log(ngx.ERR, "Failed to get rate limit from Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

if rate_limit == ngx.null then
    rate_limit = 10 -- Default rate limit if not found in Redis
else
    rate_limit = tonumber(rate_limit)
end

-- Fetch the timestamps of the requests for this IP address
local timestamps_json, err = red:hget(ip_key, rate_timestamps_field)
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
    if current_time - timestamp < window_size then
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
local _, err = red:hset(ip_key, rate_timestamps_field, new_timestamps_json)
if err then
    ngx.log(ngx.ERR, "Failed to set request timestamps in Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Set the expiration time for the IP key in Redis (window size + buffer)
local _, err = red:expire(ip_key, window_size + 10)
if err then
    ngx.log(ngx.ERR, "Failed to set expiration for rate key in Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Set the proxy_pass directive dynamically
local last_used_server_index = ngx.shared.round_robin:get("last_used_server_index") or 0
local next_server_index = (last_used_server_index % 2) + 1
ngx.shared.round_robin:set("last_used_server_index", next_server_index)

local next_server = upstream_servers[next_server_index]
ngx.var.proxy = next_server -- Correctly set the proxy variable

