local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout

-- Leaky bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local leak_rate = 1 -- Tokens leaked per second
local requested_tokens = 1 -- Number of tokens required per request

-- Helper function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR) -- 500
    end
    return red
end

-- Helper function to get URL token
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        ngx.exit(ngx.HTTP_BAD_REQUEST) -- 400
    end
    return token
end

-- Build the leaky bucket Lua script
local function get_leaky_bucket_script()
    return [[
        local tokens_key = KEYS[1]
        local last_access_key = KEYS[2]
        local bucket_capacity = tonumber(ARGV[1])
        local leak_rate = tonumber(ARGV[2])
        local now = tonumber(ARGV[3])
        local requested = tonumber(ARGV[4])
        local ttl = tonumber(ARGV[5])

        -- Fetch the current token count (if not found, assume 0)
        local last_tokens = tonumber(redis.call("get", tokens_key)) or 0

        -- Fetch the last leak time (if not found, initialize to now)
        local last_access = tonumber(redis.call("get", last_access_key)) or now

        -- Calculate the number of leaked tokens since the last access
        local elapsed = math.max(0, now - last_access)
        local leaked_tokens = math.floor(elapsed * leak_rate / 1000)
        local bucket_level = math.max(0, last_tokens - leaked_tokens)

        -- Check if we can add more tokens to the bucket
        if bucket_level < bucket_capacity then
            -- Update the bucket level with the requested number of tokens
            bucket_level = bucket_level + requested
            -- Update Redis with the new state
            redis.call("set", tokens_key, bucket_level, "EX", ttl)
            redis.call("set", last_access_key, now, "EX", ttl)
            return 1 -- Allowed
        else
            return 0 -- Not allowed (429)
        end
    ]]
end

-- Function to load the script into Redis if not already cached
local function load_script_to_redis(red, script)
    local sha = ngx.shared.my_cache:get("leaky_bucket_script_sha")
    if not sha then
        local new_sha, err = red:script("LOAD", script)
        if not new_sha then
            ngx.log(ngx.ERR, "Failed to load script: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        ngx.shared.my_cache:set("leaky_bucket_script_sha", new_sha)
        sha = new_sha
    end
    return sha
end

-- Execute the leaky bucket logic atomically
local function execute_leaky_bucket(red, sha, tokens_key, last_access_key, bucket_capacity, leak_rate, requested_tokens, ttl)
    local now = ngx.now() * 1000 -- Current time in milliseconds
    local result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, leak_rate, now, requested_tokens, ttl)

    if err then
        if err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            ngx.shared.my_cache:delete("leaky_bucket_script_sha")
            sha = load_script_to_redis(red, get_leaky_bucket_script())
            result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, leak_rate, now, requested_tokens, ttl)
        end
        
        if err then
            ngx.log(ngx.ERR, "Failed to run rate limiting script: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    end

    return result
end

-- Main function for rate limiting
local function rate_limit()
    local red = init_redis() -- Initialize Redis connection
    local token = get_token() -- Fetch and validate token

    -- Redis keys
    local tokens_key = token .. ":tokens"
    local last_access_key = token .. ":last_access"

    -- Calculate TTL for the Redis keys
    local ttl = math.floor(bucket_capacity / leak_rate * 2)

    -- Load or retrieve the Lua script SHA
    local script = get_leaky_bucket_script()
    local sha = load_script_to_redis(red, script)

    -- Execute leaky bucket logic
    local result = execute_leaky_bucket(red, sha, tokens_key, last_access_key, bucket_capacity, leak_rate, requested_tokens, ttl)

    -- Handle the result
    if result == 1 then
        ngx.say("Request allowed")
    else
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429 Too Many Requests
    end
end

-- Run the rate limiter
rate_limit()