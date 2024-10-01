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
        return nil, err
    end

    return red
end

local function get_token()
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        return nil, "Token not provided"
    end
    return token
end

local function get_script_sha(red)
    local sha = ngx.shared.my_cache:get("rate_limit_script_sha")
    if not sha then
        local redis_script = [[
            local key = KEYS[1]
            local now = tonumber(ARGV[1])
            local window = tonumber(ARGV[2])
            local limit = tonumber(ARGV[3])

            -- Remove elements outside the current window
            redis.call('ZREMRANGEBYSCORE', key, 0, now - window)

            -- Count the number of elements in the current window
            local count = redis.call('ZCARD', key)

            -- If under the limit, add the new element
            if count < limit then
                redis.call('ZADD', key, now, now)
                redis.call('EXPIRE', key, window)
                return 0
            else
                return 1
            end
        ]]
        local new_sha, err = red:script("LOAD", redis_script)
        if not new_sha then
            ngx.log(ngx.ERR, "Failed to load script: ", err)
            return nil, err
        end
        ngx.shared.my_cache:set("rate_limit_script_sha", new_sha)
        sha = new_sha
    end
    return sha
end

local function check_rate_limit()
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Construct the Redis key using the token
    local key = "rate_limit:" .. token

    -- Get the script SHA
    local sha, err = get_script_sha(red)
    if not sha then
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Get the current timestamp
    local current_time = ngx.now()

    -- Run the Lua script
    local result, err = red:evalsha(sha, 1, key, current_time, window_size, rate_limit)

    if err then
        if err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            ngx.shared.my_cache:delete("rate_limit_script_sha")
            sha, err = get_script_sha(red)
            if not sha then
                ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
            end
            result, err = red:evalsha(sha, 1, key, current_time, window_size, rate_limit)
        end

        if err then
            ngx.log(ngx.ERR, "Failed to run rate limiting script: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    end

    if result == 1 then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
end

-- Main execution
check_rate_limit()