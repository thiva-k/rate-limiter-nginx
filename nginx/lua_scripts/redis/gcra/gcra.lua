local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout

-- GCRA parameters
local period = 60 -- Time window of 1 minute
local rate = 5 -- 5 requests per minute
local burst = 2 -- Allow burst of up to 2 requests
local emission_interval = period / rate
local delay_tolerance = emission_interval * burst

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

-- Main GCRA rate limiting logic
local function rate_limit()
    -- Initialize Redis connection
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Get token from the request URL
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Redis key for storing the user's TAT (Theoretical Arrival Time)
    local redis_key = "rate_limit:" .. token

    -- Fetch the stored TAT from Redis
    local tat, err = red:get(redis_key)
    if not tat or tat == ngx.null then
        tat = -1 -- Initial value if no previous TAT exists
    else
        tat = tonumber(tat)
    end

    -- Get the current time (in seconds)
    local current_time = ngx.now()

    -- If it's the first request, initialize the TAT to the current time
    if tat == -1 then
        tat = current_time
    end

    -- Compute the time when the request is allowed
    local allow_at = tat - delay_tolerance

    -- Check if the current request is allowed
    if current_time >= allow_at then
        -- Request is allowed, so update the TAT to the next allowed time
        tat = math.max(current_time, tat) + emission_interval

        -- Store the updated TAT in Redis with a TTL longer than the burst period to avoid stale data
        local ttl = math.ceil((tat - current_time) + delay_tolerance)
        local ok, err = red:set(redis_key, tat, "EX", ttl)
        if not ok then
            ngx.log(ngx.ERR, "Failed to update TAT in Redis: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        ngx.say("Request allowed")
    else
        -- Request is not allowed
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429
    end
end

-- Run the rate limiter
rate_limit()
