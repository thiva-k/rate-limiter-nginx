local redis = require "resty.redis"
local cjson = require "cjson"

local redis_host = "redis"
local redis_port = 6379
local rate_limit = 10   -- 10 requests in a 20 seconds window
local window_size = 20  -- Sliding window size in seconds
local batch_size = 5    -- Number of requests allowed in a batch
local shared_dict = ngx.shared.rate_limit_dict -- Shared memory dictionary

-- Fetch token from request
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

-- Redis key for this token
local redis_key = "sliding_window_counter:" .. token

-- Initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(1000)  -- 1 second timeout
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
        return nil, err
    end
    return red
end

-- Function to clean up old requests from Redis and return current count
local function remove_expired_and_fetch_count(red)
    local current_time = ngx.now()
    local window_start = current_time - window_size

    -- Remove old requests that are outside the sliding window
    local _, err = red:zremrangebyscore(redis_key, 0, window_start)
    if err then
        ngx.log(ngx.ERR, "Failed to remove old requests: ", err)
        return nil, err
    end

    -- Fetch the current count of requests in the window
    local count, err = red:zcard(redis_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get request count: ", err)
        return nil, err
    end

    return count
end

-- Function to fetch a batch of allowed requests and update Redis
local function fetch_batch_and_update_redis(red)
    -- Clean up old requests and get the current valid request count
    local current_count = remove_expired_and_fetch_count(red)
    if not current_count then
        return nil
    end

    -- Calculate remaining quota in the window
    local remaining_quota = math.max(0, rate_limit - current_count)
    if remaining_quota == 0 then
        return 0  -- No more requests allowed in this window
    end

    -- Determine the number of requests that can be fetched (batch size)
    local batch_quota = math.min(batch_size, remaining_quota)

    -- Add the current timestamp for each request in the batch
    local current_time = ngx.now()
    for i = 1, batch_quota do
        local ts = current_time + i / 1000  -- Spread timestamps slightly
        red:zadd(redis_key, ts, ts)
    end

    return batch_quota
end

-- Main function to check if a request is allowed
local function is_request_allowed()
    -- Retrieve current batch count from shared memory
    local batch_count = shared_dict:get(redis_key .. ":batch_count") or 0

    -- If we have a batch available, decrement and allow the request
    if batch_count > 0 then
        shared_dict:incr(redis_key .. ":batch_count", -1) -- Decrement local batch count
        return true
    end

    -- Otherwise, fetch a new batch from Redis
    local red, err = init_redis()
    if not red then
        return false
    end

    -- Fetch a new batch of requests
    local new_batch_quota = fetch_batch_and_update_redis(red)
    if not new_batch_quota or new_batch_quota == 0 then
        return false  -- Rate limit exceeded
    end

    -- Store new batch count in shared memory
    shared_dict:set(redis_key .. ":batch_count", new_batch_quota)

    -- Allow the request
    return true
end

-- Handle the incoming request
if is_request_allowed() then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end
