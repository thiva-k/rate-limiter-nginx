local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout

-- Leaky bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local leak_rate = 1 -- Tokens leaked per second
local requested_tokens = 1 -- Number of tokens required per request
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

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

-- Lua script to implement leaky bucket algorithm
local function get_rate_limit_script()
    return [[
        local tokens_key = KEYS[1]
        local last_access_key = KEYS[2]
        local bucket_capacity = tonumber(ARGV[1])
        local leak_rate = tonumber(ARGV[2])
        local requested = tonumber(ARGV[3])
        local ttl = tonumber(ARGV[4])
        
        local redis_time = redis.call("TIME")
        local now = tonumber(redis_time[1]) * 1000000 + tonumber(redis_time[2]) -- Convert to microseconds

        local values = redis.call("mget", tokens_key, last_access_key)
        local last_tokens = tonumber(values[1]) or 0
        local last_access = tonumber(values[2]) or now
        
        local elapsed = math.max(0, now - last_access)
        local leaked_tokens = math.floor(elapsed * leak_rate / 1000000)
        local bucket_level = math.max(0, last_tokens - leaked_tokens)

        if bucket_level + requested <= bucket_capacity then
            -- Calculate default delay between requests based on leak rate in microseconds
            local delay_between_requests = 1 / leak_rate * 1000000

            -- Assumption: Atleast 1us delay will be there between request processing
            -- If time difference either 0 or greater than delay_between_requests then no need to add delay
            local time_diff = now - last_access
            local delay = 0
            if time_diff < 0 or (time_diff > 0 and time_diff < delay_between_requests) then
                delay = -time_diff + delay_between_requests
            end

            -- For the first request no need to increment the bucket level as we allow it immediately
            if delay ~= 0 or bucket_level ~= 0 then
                bucket_level = bucket_level + requested
            end

            redis.call("set", tokens_key, bucket_level, "EX", ttl)
            redis.call("set", last_access_key, now + delay, "EX", ttl)
            
            return delay
        else
            return -1
        end
    ]]
end

-- Function to load the script into Redis if not already cached
local function load_script_to_redis(red, script)
    local sha = ngx.shared.my_cache:get("rate_limit_script_sha")
    if not sha then
        local new_sha, err = red:script("LOAD", script)
        if not new_sha then
            return nil, err
        end
        ngx.shared.my_cache:set("rate_limit_script_sha", new_sha)
        sha = new_sha
    end
    return sha
end

-- Execute the leaky bucket logic atomically
local function execute_rate_limit(red, sha, tokens_key, last_access_key, ttl)
    local result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, leak_rate, requested_tokens, ttl)

    if err then
        if err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            ngx.shared.my_cache:delete("rate_limit_script_sha")
            sha, err = load_script_to_redis(red, get_rate_limit_script())
            if not sha then
                return nil, err
            end
            result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, leak_rate, requested_tokens, ttl)
        end

        if err then
            return nil, err
        end
    end

    return result
end

-- Main function for rate limiting
local function rate_limit(red, token)
    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    -- Calculate TTL for the Redis keys
    local ttl = math.floor(bucket_capacity / leak_rate * 2)

    -- Load or retrieve the Lua script SHA
    local script = get_rate_limit_script()
    local sha, err = load_script_to_redis(red, script)
    if not sha then
        ngx.log(ngx.ERR, "Failed to load script: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Execute leaky bucket logic
    local result, err = execute_rate_limit(red, sha, tokens_key, last_access_key, ttl)
    if not result then
        ngx.log(ngx.ERR, "Failed to run rate limiting script: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Handle the result
    if result == -1 then
        return ngx.HTTP_TOO_MANY_REQUESTS
    else
        -- Nginx sleep supports second with milliseconds precision 
        local rounded_delay = math.floor(result / 1000 + 0.5) / 1000 -- Round to 3 decimal places
        ngx.sleep(rounded_delay) -- Convert microseconds to seconds
        ngx.say("Request allowed")
        return ngx.HTTP_OK
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

