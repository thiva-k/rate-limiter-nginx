local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis-enterprise-1"
local redis_port = 12000
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local rate_limit = 100
local window_size = 60 -- 60 second window

-- Helper function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, err
    end
    return red
end

-- Helper function to close Redis connection
local function close_redis(red)
    local ok, err = red:set_keepalive(max_idle_timeout, pool_size)
    if not ok then
        return nil, err
    end
    return true
end

-- Helper function to get URL token
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Helper function to get script SHA
local function get_script_sha(red)
    local sha = ngx.shared.my_cache:get("fixed_window_script_sha")
    if not sha then
        local redis_script = [[
            local key = KEYS[1]
            local window_size = tonumber(ARGV[1])
            local rate_limit = tonumber(ARGV[2])
            
            -- Get current Redis time in seconds and microseconds
            local time = redis.call('TIME')
            local current_time = tonumber(time[1])
            
            -- Calculate window start time
            local window_start = math.floor(current_time / window_size) * window_size
            
            -- Construct the rate limit key with window start time
            local rate_key = key .. ':' .. window_start
            
            -- Increment the counter
            local counter = redis.call('INCR', rate_key)
            
            -- If this is the first request in the window, set the expiry
            if counter == 1 then
                redis.call('EXPIRE', rate_key, window_size)
            end
            
            -- Check if we've exceeded the rate limit
            if counter > rate_limit then
                return 1 -- Rate limit exceeded
            end
            
            return 0 -- Request allowed
        ]]
        
        local new_sha, err = red:script("LOAD", redis_script)
        if not new_sha then
            return nil, "Failed to load script: " .. err
        end
        ngx.shared.my_cache:set("fixed_window_script_sha", new_sha)
        sha = new_sha
    end
    return sha
end

-- Main rate limiting logic
local function check_rate_limit(red, token)
    local sha, err = get_script_sha(red)
    if not sha then
        return ngx.HTTP_INTERNAL_SERVER_ERROR, err
    end

    local result, err = red:evalsha(sha, 1, "rate_limit:{" .. token .. "}", window_size, rate_limit)
    if err then
        if err:find("NOSCRIPT", 1, true) then
            ngx.shared.my_cache:delete("fixed_window_script_sha")
            sha, err = get_script_sha(red)
            if not sha then
                return ngx.HTTP_INTERNAL_SERVER_ERROR, err
            end
            result, err = red:evalsha(sha, 1, "rate_limit:" .. token, window_size, rate_limit)
        end
        if err then
            return ngx.HTTP_INTERNAL_SERVER_ERROR, "Failed to run rate limiting script: " .. err
        end
    end

    if result == 1 then
        return ngx.HTTP_TOO_MANY_REQUESTS
    end

    return ngx.HTTP_OK
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local success, status, err = pcall(check_rate_limit, red, token)
    local ok, close_err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", close_err)
    end

    if not success then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif err then
        ngx.log(ngx.ERR, err)
        ngx.exit(status)
    elseif status == ngx.HTTP_TOO_MANY_REQUESTS then
        ngx.exit(status)
    end
end

-- Run the main function
main()