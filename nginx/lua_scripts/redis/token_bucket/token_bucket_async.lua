local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Token bucket parameters
local bucket_capacity = 10
local refill_rate = 1 -- tokens per second
local requested_tokens = 1 -- tokens required per request -- TODO: have to think about how to process when the requested_tokens is greater than 1
local batch_percent = 0.2 -- 20% of remaining tokens for batch quota
local min_batch_quota = 1

-- Helper function to initialize shared dictionary
local function init_shared_dict()
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
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

-- Helper function to close Redis connection
local function close_redis(red)
    local ok, err = red:set_keepalive(max_idle_timeout, pool_size)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set keepalive: ", err)
    end
end

-- Helper function to acquire a lock
local function aquire_lock(token)
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(token)
    if not elapsed then
        ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
        return nil, err
    end
    return lock
end

-- Helper function to release the lock
local function release_lock(lock)
    lock:unlock()
end

-- Helper function to get URL token
local function get_user_url_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Redis script to reduce the batch quota and update the token bucket
local function get_rate_limit_script()
    return [[
        local tokens_key = KEYS[1]
        local last_access_key = KEYS[2]
        local bucket_capacity = tonumber(ARGV[1])
        local refill_rate = tonumber(ARGV[2])
        local requested_tokens = tonumber(ARGV[3])
        local ttl = tonumber(ARGV[4])

        local redis_time = redis.call("TIME")
        local now = tonumber(redis_time[1]) * 1000000 + tonumber(redis_time[2]) -- Convert to microseconds

        local values = redis.call("mget", tokens_key, last_access_key)
        local last_tokens = tonumber(values[1]) or bucket_capacity
        local last_access = tonumber(values[2]) or now

        local elapsed = math.max(0, now - last_access)
        local add_tokens = elapsed * refill_rate / 1000000
        local new_tokens = math.max(math.floor(math.min(bucket_capacity, last_tokens + add_tokens - requested_tokens) * 1000000 + 0.5) / 1000000, 0)

        redis.call("set", tokens_key, new_tokens, "EX", ttl)
        redis.call("set", last_access_key, now, "EX", ttl)

        return new_tokens
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

-- Execute the token bucket logic atomically
local function execute_rate_limit(red, sha, tokens_key, last_access_key, batch_used, ttl)
    local result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, refill_rate, batch_used, ttl)

    if err and err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        ngx.shared.my_cache:delete("rate_limit_script_sha")
        sha, err = load_script_to_redis(red, get_rate_limit_script())
        if not sha then
            return nil, err
        end
        result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, refill_rate, batch_used, ttl)
    end

    if err then
        return nil, err
    end

    return result
end

-- Function to fetch and set batch quota
local function fetch_batch_quota(token, shared_dict, remaining_tokens)
    local batch_quota
    if remaining_tokens < 1 then
        batch_quota = 0
    else
        batch_quota = math.max(min_batch_quota, math.floor(remaining_tokens * batch_percent))
    end

    local ok, err = shared_dict:set(token .. ":batch_quota", batch_quota, ttl)
    if not ok then
        return nil, "Failed to set batch_quota in shared_dict: " .. err
    end

    ok, err = shared_dict:set(token .. ":batch_used", 0, ttl)
    if not ok then
        return nil, "Failed to set batch_used in shared_dict: " .. err
    end

    return batch_quota, nil
end

-- Main rate limiting logic
local function rate_limit(red, token, shared_dict)
    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    -- Calculate TTL based on bucket capacity and refill rate
    local ttl = math.floor(bucket_capacity / refill_rate * 2)

    -- Load or retrieve the Lua script SHA
    local script = get_rate_limit_script()
    local sha, err = load_script_to_redis(red, script)
    if not sha then
        ngx.log(ngx.ERR, "Failed to load script: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    local batch_quota = shared_dict:get(token .. ":batch_quota") or 0
    local batch_used = shared_dict:get(token .. ":batch_used") or 0

    -- Initialize the batch quota
    if batch_quota == 0 then
        local remaining_tokens, err = execute_rate_limit(red, sha, tokens_key, last_access_key, 0, ttl)
        if not remaining_tokens then
            ngx.log(ngx.ERR, err)
            return ngx.HTTP_INTERNAL_SERVER_ERROR
        end

        batch_quota, err = fetch_batch_quota(token, shared_dict, remaining_tokens)
        if err then
            ngx.log(ngx.ERR, err)
            return ngx.HTTP_INTERNAL_SERVER_ERROR
        end
        batch_used = 0
    end

    if batch_used < batch_quota then
        local new_batch_used, err = shared_dict:incr(token .. ":batch_used", 1)
        if not new_batch_used then
            ngx.log(ngx.ERR, "Failed to increment batch_used in shared_dict: ", err)
            return ngx.HTTP_INTERNAL_SERVER_ERROR
        end

        if new_batch_used == batch_quota then
            -- Batch quota exceeded, fetch new batch quota based on remaining tokens
            local remaining_tokens, err = execute_rate_limit(red, sha, tokens_key, last_access_key, new_batch_used, ttl)
            if not remaining_tokens then
                ngx.log(ngx.ERR, err)
                return ngx.HTTP_INTERNAL_SERVER_ERROR
            end

            batch_quota, err = fetch_batch_quota(token, shared_dict, remaining_tokens)
            if err then
                ngx.log(ngx.ERR, err)
                return ngx.HTTP_INTERNAL_SERVER_ERROR
            end
        end

        ngx.say("Request allowed")
        return ngx.HTTP_OK
    else
        return ngx.HTTP_TOO_MANY_REQUESTS -- 42
    end
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    local token, err = get_user_url_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local shared_dict = init_shared_dict()
    if not shared_dict then
        ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local lock, err = aquire_lock(token)
    if not lock then
        ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Rate limit the request
    local ok, status = pcall(rate_limit, red, token, shared_dict)

    release_lock(lock)

    close_redis(red)

    if not ok then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    else
        ngx.exit(status)
    end
end

-- Run the rate limiter
main()
