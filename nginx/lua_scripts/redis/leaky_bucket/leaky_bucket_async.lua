local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout

-- Leaky bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local leak_rate = 1 -- Tokens leaked per second
local requested_tokens = 1 -- Number of tokens required per request
local batch_percent = 0.2 -- 20% of remaining tokens for batch quota
local min_batch_quota = 1

-- Helper function to initialize shared dictionary
local function init_shared_dict()
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
        return nil
    end
    return shared_dict
end

-- Helper function to initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout) -- 1 second timeout

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, err
    end

    return red
end

-- Helper function to get URL token
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Redis script to reduce the batch quota and update the leaky bucket
local function get_leaky_bucket_script()
    return [[
        local tokens_key = KEYS[1]
        local last_access_key = KEYS[2]
        local bucket_capacity = tonumber(ARGV[1])
        local leak_rate = tonumber(ARGV[2])
        local now = tonumber(ARGV[3])
        local requested = tonumber(ARGV[4])
        local ttl = tonumber(ARGV[5])

        local last_tokens = tonumber(redis.call("get", tokens_key)) or 0
        local last_access = tonumber(redis.call("get", last_access_key)) or now

        local elapsed = math.max(0, now - last_access)
        local leaked_tokens = math.floor(elapsed * leak_rate / 1000)
        local bucket_level = math.min(math.max(0, last_tokens - leaked_tokens + requested), bucket_capacity)
        local remaining_tokens = bucket_capacity - bucket_level

        redis.call("set", tokens_key, bucket_level, "EX", ttl)
        redis.call("set", last_access_key, now, "EX", ttl)

        return remaining_tokens
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
local function execute_leaky_bucket(red, sha, tokens_key, last_access_key, bucket_capacity, leak_rate, requested_tokens, ttl)
    local now = ngx.now() * 1000 -- Current time in milliseconds
    local result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, leak_rate, now, requested_tokens, ttl)

    if err and err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        ngx.shared.my_cache:delete("rate_limit_script_sha")
        sha, err = load_script_to_redis(red, get_leaky_bucket_script())
        if not sha then
            return nil, err
        end
        result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, leak_rate, now, requested_tokens, ttl)
    end

    if err then
        return nil, err
    end

    return result
end

-- Main function for rate limiting
local function rate_limit()
    -- Initialize Redis connection
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Initialize shared dictionary
    local shared_dict = init_shared_dict()
    if not shared_dict then
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    
    -- Get token from the request URL
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    -- Calculate TTL based on bucket capacity and leak rate
    local ttl = math.floor(bucket_capacity / leak_rate * 2)

    -- Load or retrieve the Lua script SHA
    local script = get_leaky_bucket_script()
    local sha, err = load_script_to_redis(red, script)
    if not sha then
        ngx.log(ngx.ERR, "Failed to load script: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Use a lock to ensure only one worker fetches the quota at a time
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(token)
    if not elapsed then
        ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local batch_quota = shared_dict:get(token .. ":batch_quota") or 0
    local batch_used = shared_dict:get(token .. ":batch_used") or 0

    if batch_quota == 0 then
        -- Fetch new batch quota based on remaining tokens
        local remaining_tokens, err = execute_leaky_bucket(red, sha, tokens_key, last_access_key, bucket_capacity, leak_rate, 0, ttl)
        if not remaining_tokens then
            ngx.log(ngx.ERR, "Failed to run rate limiting script: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        if remaining_tokens == 0 then
            batch_quota = 0
        else 
            batch_quota = math.max(min_batch_quota, math.floor(remaining_tokens * batch_percent))
        end

        local ok, err = shared_dict:set(token .. ":batch_quota", batch_quota, ttl)
        if not ok then
            ngx.log(ngx.ERR, "Failed to set batch_quota in shared_dict: ", err)
            lock:unlock() -- Release the lock
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        ok, err = shared_dict:set(token .. ":batch_used", 0, ttl)
        if not ok then
            ngx.log(ngx.ERR, "Failed to set batch_used in shared_dict: ", err)
            lock:unlock() -- Release the lock
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        batch_used = 0
    end

    if batch_used >= batch_quota then
        -- Batch quota exceeded, fetch new batch quota based on remaining tokens
        local remaining_tokens, err = execute_leaky_bucket(red, sha, tokens_key, last_access_key, bucket_capacity, leak_rate, batch_used, ttl)
        if not remaining_tokens then
            ngx.log(ngx.ERR, "Failed to run rate limiting script: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        if remaining_tokens == 0 then
            batch_quota = 0
        else 
            batch_quota = math.max(min_batch_quota, math.floor(remaining_tokens * batch_percent))
        end

        local ok, err = shared_dict:set(token .. ":batch_quota", batch_quota, ttl)
        if not ok then
            ngx.log(ngx.ERR, "Failed to set batch_quota in shared_dict: ", err)
            lock:unlock() -- Release the lock
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        ok, err = shared_dict:set(token .. ":batch_used", 0, ttl)
        if not ok then
            ngx.log(ngx.ERR, "Failed to set batch_used in shared_dict: ", err)
            lock:unlock() -- Release the lock
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        batch_used = 0
    end
    
    if batch_used < batch_quota then
        local new_batch_used, err = shared_dict:incr(token .. ":batch_used", 1)
        if not new_batch_used then
            ngx.log(ngx.ERR, "Failed to increment batch_used in shared_dict: ", err)
            lock:unlock() -- Release the lock
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        
        lock:unlock() -- Release the lock
        ngx.say("Request allowed")
    else
        lock:unlock() -- Release the lock
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429
    end
end

-- Run the rate limiter
rate_limit()