local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- GCRA parameters
local period = 60 -- Time window of 1 minute
local rate = 5 -- 5 requests per minute
local burst = 2 -- Allow burst of up to 2 requests
local emission_interval = period / rate
local delay_tolerance = emission_interval * burst

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
local function get_user_url_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end

    return token
end

-- Function to get the GCRA rate limit Lua script
local function get_gcra_script()
    return [[
        local tat_key = KEYS[1]
        local emission_interval = tonumber(ARGV[1])
        local delay_tolerance = tonumber(ARGV[2])

        -- Get the current time from Redis
        local redis_time = redis.call("TIME")
        local current_time = tonumber(redis_time[1]) + tonumber(redis_time[2]) / 1000000

        -- Retrieve the last TAT
        local last_tat = redis.call("GET", tat_key)
        last_tat = tonumber(last_tat) or current_time

        -- Calculate the allowed arrival time
        local allow_at = last_tat - delay_tolerance

        -- Check if the request is allowed
        if current_time >= allow_at then
            -- Request allowed; calculate the new TAT
            local new_tat = math.max(current_time, last_tat) + emission_interval
            
            -- Calculate TTL based on the new TAT and the current time
            local ttl = math.ceil(new_tat - current_time + delay_tolerance)

            -- Store the updated TAT with calculated TTL
            redis.call("SET", tat_key, new_tat, "EX", ttl)
            return 1  -- Request allowed
        else
            return 0  -- Request denied
        end
    ]]
end

-- Load the GCRA script into Redis if not already cached
local function load_script_to_redis(red, script)
    local sha = ngx.shared.my_cache:get("gcra_script_sha")
    if not sha then
        local new_sha, err = red:script("LOAD", script)
        if not new_sha then
            return nil, err
        end
        ngx.shared.my_cache:set("gcra_script_sha", new_sha)
        sha = new_sha
    end

    return sha
end

-- Execute the GCRA logic atomically
local function execute_gcra_rate_limit(red, sha, tat_key)
    local result, err = red:evalsha(sha, 1, tat_key, emission_interval, delay_tolerance)

    if err and err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        ngx.shared.my_cache:delete("gcra_script_sha")
        sha, err = load_script_to_redis(red, get_gcra_script())
        if not sha then
            return nil, err
        end
        result, err = red:evalsha(sha, 1, tat_key, emission_interval, delay_tolerance)
    end

    if err then
        return nil, err
    end

    return result
end

-- Main GCRA rate limiting logic
local function rate_limit(red, token)
    -- Redis key for storing the user's TAT (Theoretical Arrival Time)
    local tat_key = "rate_limit:" .. token .. ":tat"

    -- Load or retrieve the Lua script SHA
    local script = get_gcra_script()
    local sha, err = load_script_to_redis(red, script)
    if not sha then
        ngx.log(ngx.ERR, "Failed to load script: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Execute GCRA logic
    local result, err = execute_gcra_rate_limit(red, sha, tat_key)
    if not result then
        ngx.log(ngx.ERR, "Failed to run rate limiting script: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Handle the result
    if result == 1 then
        ngx.say("Request allowed")
        return ngx.HTTP_OK
    else
        return ngx.HTTP_TOO_MANY_REQUESTS
    end
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    local token, err = get_user_url_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local res, status = pcall(rate_limit, red, token)

    local ok, err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", err)
    end

    if not res then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    else
        ngx.exit(status)
    end
end

-- Run the main function
main()