local redis = require "resty.redis"
local redis_host = "redis"
local redis_port = 6379
local rate_limit = 5 -- 5 requests per minute
local window_size = 60 -- 60 second window

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

-- Construct the Redis key using only the token
local redis_key = "rate_limit:" .. token

-- Lua script for atomic rate limiting
local limit_script = [[
    local key = KEYS[1]
    local limit = tonumber(ARGV[1])
    local window = tonumber(ARGV[2])
    
    local current = redis.call('get', key)
    if current and tonumber(current) >= limit then
        return tonumber(current)
    end
    
    current = redis.call('incr', key)
    if tonumber(current) == 1 then
        redis.call('expire', key, window)
    end
    
    return tonumber(current)
]]

-- Function to get or set the script SHA
local function get_script_sha(red)
    local sha = ngx.shared.my_cache:get("rate_limit_script_sha")
    if not sha then
        local new_sha, err = red:script("LOAD", limit_script)
        if not new_sha then
            ngx.log(ngx.ERR, "Failed to load script: ", err)
            return nil, err
        end
        ngx.shared.my_cache:set("rate_limit_script_sha", new_sha)
        sha = new_sha
    end
    return sha
end

-- Get the script SHA
local sha, err = get_script_sha(red)
if not sha then
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Run the Lua script
local resp, err = red:evalsha(sha, 1, redis_key, rate_limit, window_size)

if err then
    if err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        ngx.shared.my_cache:delete("rate_limit_script_sha")
        sha, err = get_script_sha(red)
        if not sha then
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        resp, err = red:evalsha(sha, 1, redis_key, rate_limit, window_size)
    end
    
    if err then
        ngx.log(ngx.ERR, "Failed to run rate limiting script: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
end

if resp >= rate_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end
