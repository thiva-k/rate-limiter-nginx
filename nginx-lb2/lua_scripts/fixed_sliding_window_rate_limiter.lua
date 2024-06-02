local upstream_servers = { "server1:8080", "server2:8080" }

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
    ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Define the key for rate limiting
local ip_key = ngx.var.remote_addr
local rate_limit_field = "rate_limit"
local rate_field = "rate"

-- Fetch the specific rate limit and current rate for this IP address from Redis
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

local current_rate, err = red:hget(ip_key, rate_field)
if err then
    ngx.log(ngx.ERR, "Failed to get current rate from Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

if current_rate == ngx.null then
    current_rate = 0
else
    current_rate = tonumber(current_rate)
end

ngx.log(ngx.INFO, "Current rate: ", current_rate)

-- Increment the rate in Redis
local new_rate = current_rate + 1
local _, err = red:hset(ip_key, rate_field, new_rate)
if err then
    ngx.log(ngx.ERR, "Failed to set rate in Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Set the expiration time for the rate field in Redis (1 minute)
local _, err = red:expire(ip_key, 60)
if err then
    ngx.log(ngx.ERR, "Failed to set expiration for rate key in Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Check if the rate exceeds the limit
if new_rate > rate_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Get the last used server index from shared memory
local last_used_server_index = ngx.shared.round_robin:get("last_used_server_index") or 0

-- Calculate the next server index in round-robin fashion
local next_server_index = (last_used_server_index % 2) + 1
ngx.shared.round_robin:set("last_used_server_index", next_server_index)

-- Set the proxy_pass directive dynamically
local next_server = upstream_servers[next_server_index]
ngx.var.proxy = next_server
