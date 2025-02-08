local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis-enterprise"
local redis_port = 12000
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local rate_limit = 10 -- Maximum number of requests allowed per window
local window_size = 60 -- Time window in seconds

-- Lua script for atomic rate limiting with fixed window
local limit_script = [[
    local key = KEYS[1]
    local limit = tonumber(ARGV[1])
    local ttl = tonumber(ARGV[2])
    
    local current = redis.call('incr', key)
    if current == 1 then
        redis.call('expire', key, ttl)
    end

    return current
]]


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

-- Function to get or set the script SHA in shared memory
local function get_script_sha(red)
    local sha = ngx.shared.my_cache:get("rate_limit_script_sha")
    if not sha then
        local new_sha, err = red:script("LOAD", limit_script)
        if not new_sha then
            return nil, "Failed to load script: " .. err
        end
        ngx.shared.my_cache:set("rate_limit_script_sha", new_sha)
        sha = new_sha
    end
    return sha
end

-- Function to run the rate limiting script
local function run_rate_limit_script(red, redis_key, window_size)
    local sha, err = get_script_sha(red)
    if not sha then
        return nil, err
    end
    
    local resp, err = red:evalsha(sha, 1, redis_key, rate_limit, window_size)
    
    if err then
        if err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            ngx.shared.my_cache:delete("rate_limit_script_sha")
            sha, err = get_script_sha(red)
            if not sha then
                return nil, err
            end
            resp, err = red:evalsha(sha, 1, redis_key, rate_limit, window_size)
        end
        
        if err then
            return nil, "Failed to run rate limiting script: " .. err
        end
    end
    
    return resp
end

-- Main rate limiting logic
local function check_rate_limit(red, token)
    -- Get the current timestamp and round it down to the nearest minute
    local current_time = ngx.now()
    local window_start = math.floor(current_time / window_size) * window_size

    -- Construct the Redis key using the token and the window start time
    local redis_key = string.format("rate_limit:%s:%d", token, window_start)

    -- Run the rate limiting script with window_size as TTL
    local resp, err = run_rate_limit_script(red, redis_key, window_size)
    if not resp then
        return nil, err
    end

    -- Check if the rate limit has been exceeded
    if resp > rate_limit then
        return ngx.HTTP_TOO_MANY_REQUESTS
    end

    return ngx.HTTP_OK
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    -- Get token from URL parameters
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Initialize Redis connection
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Run rate limiting check with error handling
    local res, status = pcall(check_rate_limit, red, token)
    
    -- Properly close Redis connection
    local ok, close_err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", close_err)
    end

    -- Handle any errors from the rate limiting check
    if not res then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif status == ngx.HTTP_TOO_MANY_REQUESTS then
        ngx.exit(status)
    end
end

-- Run the main function
main()