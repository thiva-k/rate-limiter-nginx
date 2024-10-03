local redis = require "resty.redis"

-- Global variables
local redis_host = "redis"
local redis_port = 6379
local rate_limit = 500 -- 500 requests per minute
local window_size = 60 -- 1 minute window

local function init_redis()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    return red
end

local function get_token()
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    return token
end

local function remove_old_entries_and_count(red, key, current_time)
    red:multi()
    red:zremrangebyscore(key, 0, current_time - window_size)
    red:zcard(key)
    local results, err = red:exec()
    if not results then
        ngx.log(ngx.ERR, "Failed to execute Redis transaction: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    return results[2] -- Return the count
end

local function add_new_entry(red, key, current_time)
    red:multi()
    red:zadd(key, current_time, current_time)
    red:expire(key, window_size)
    local results, err = red:exec()

    if not results then
        ngx.log(ngx.ERR, "Failed to execute Redis transaction: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
end

local function check_rate_limit()
    local red = init_redis()
    local token = get_token()
    local key = "rate_limit:" .. token
    local current_time = ngx.now()

    local count = remove_old_entries_and_count(red, key, current_time)
    if count >= rate_limit then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
    add_new_entry(red, key, current_time)
end

-- Main execution
check_rate_limit()