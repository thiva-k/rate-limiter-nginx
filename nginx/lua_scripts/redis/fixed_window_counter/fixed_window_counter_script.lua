local redis = require "resty.redis"

-- Global variables
local redis_host = "redis"
local redis_port = 6379
local rate_limit = 500 -- Maximum number of requests allowed per window
local window_size = 60 -- Time window in seconds

-- Lua script for atomic rate limiting
local limit_script = [[
    local key = KEYS[1]
    local limit = tonumber(ARGV[1])
    local window = tonumber(ARGV[2])
    
    local current = redis.call('get', key)
    if current then
        current = tonumber(current)
        if current >= limit then
            return limit + 1  -- Return a value greater than limit to indicate rate limit exceeded
        end
    else
        current = 0
    end
    
    current = current + 1
    redis.call('set', key, current)
    if current == 1 then
        redis.call('expire', key, window)
    end
    
    return current
]]

-- Function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout
    
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, "Failed to connect to Redis: " .. err
    end
    
    return red
end

-- Function to retrieve the token from URL parameters
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
        -- If SHA is not in cache, load the script into Redis
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
local function run_rate_limit_script(red, redis_key)
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

-- Main function to check rate limit
local function check_rate_limit()
    -- Initialize Redis connection
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Get token from URL parameters
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Construct the Redis key using only the token
    local redis_key = "rate_limit:" .. token

    -- Run the rate limiting script
    local resp, err = run_rate_limit_script(red, redis_key)
    if not resp then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Check if the rate limit has been exceeded
    if resp > rate_limit then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
end

-- Main execution
check_rate_limit()