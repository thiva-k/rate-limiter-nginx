local redis = require "resty.redis"
local resty_lock = require "resty.lock"
local cjson = require "cjson"

-- Configuration
local redis_host = "redis"         -- Redis server host
local redis_port = 6379            -- Redis server port
local redis_timeout = 1000         -- 1 second timeout
local max_idle_timeout = 10000     -- 10 seconds
local pool_size = 100             -- Maximum number of idle connections in the pool
local rate_limit = 500             -- Max requests allowed in the window
local batch_percent = 0.1          -- Percentage of remaining requests to allow in a batch
local min_batch_size = 1           -- Minimum size of batch
local window_size = 60             -- Time window size in seconds

-- Quota stealing configuration
local node_id = os.getenv("NODE_ID") or ngx.worker.pid()
local steal_request_channel = "quota_steal_requests"
local steal_response_channel = "quota_steal_responses:"
local steal_timeout = 1  -- 1 second timeout for steal requests

-- Initialize Redis connection with pooling
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout)

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, "Failed to connect to Redis: " .. err
    end

    return red
end

-- Close Redis connection with keepalive for pooling
local function close_redis(red)
    local ok, err = red:set_keepalive(max_idle_timeout, pool_size)
    if not ok then
        return nil, err
    end
    return true
end

-- Retrieve token from URL parameter
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Access Nginx shared dictionary
local function get_shared_dict()
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        return nil, "Failed to access shared dictionary"
    end
    return shared_dict
end

-- Calculate remaining TTL in the current window
local function calculate_ttl()
    local current_time = ngx.now()
    local window_start = math.floor(current_time / window_size) * window_size
    local ttl = window_size - (current_time - window_start)
    return math.max(1, math.ceil(ttl))
end

-- Fetch batch quota from Redis
local function fetch_batch_quota(red, redis_key)
    local count, err = red:get(redis_key)
    if err then
        return nil, "Failed to GET from Redis: " .. err
    end

    count = tonumber(count) or 0
    local remaining = rate_limit - count

    if remaining <= 0 then
        return 0
    end

    local batch_size = math.floor(remaining * batch_percent)
    batch_size = math.max(batch_size, min_batch_size)
    batch_size = math.min(batch_size, remaining)

    return batch_size
end

-- Update Redis with the exhausted batch count and set TTL if necessary
local function update_redis_with_exhausted_batch(red, redis_key, batch_quota, ttl)
    local new_count, err = red:incrby(redis_key, batch_quota)
    if err then
        return nil, "Failed to INCRBY in Redis: " .. err
    end

    -- Set expiration if this is the first batch
    if new_count == batch_quota then
        red:expire(redis_key, ttl)
    end

    return true
end

-- Set new batch quota and reset used count in shared memory
local function set_new_batch(shared_dict, redis_key, batch_size, ttl)
    local ok, err = shared_dict:set(redis_key .. ":batch", batch_size, ttl)
    if not ok then
        return nil, "Failed to set batch quota in shared memory: " .. err
    end

    ok, err = shared_dict:set(redis_key .. ":used", 0, ttl)
    if not ok then
        return nil, "Failed to reset used count in shared memory: " .. err
    end

    return true
end

-- Try to steal quota from peer nodes
local function try_steal_quota(shared_dict, redis_key, ttl)
    local red = redis:new()
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, "Failed to connect to Redis for quota stealing"
    end

    -- Publish steal request
    local request = {
        requester_id = node_id,
        redis_key = redis_key,
        timestamp = ngx.now()
    }
    
    ok, err = red:publish(steal_request_channel, cjson.encode(request))
    if not ok then
        return nil, "Failed to publish steal request"
    end

    -- Subscribe to our response channel
    ok, err = red:subscribe(steal_response_channel .. node_id)
    if not ok then
        return nil, "Failed to subscribe to response channel"
    end

    -- Wait for responses with timeout
    local start_time = ngx.now()
    while (ngx.now() - start_time) < steal_timeout do
        local res, err = red:read_reply()
        if res and res[1] == "message" then
            local response = cjson.decode(res[3])
            if response.quota > 0 then
                -- Update our local batch quota with stolen quota
                ok, err = shared_dict:set(redis_key .. ":batch", response.quota, ttl)
                if not ok then
                    return nil, "Failed to set stolen quota"
                end
                -- Reset used count
                ok, err = shared_dict:set(redis_key .. ":used", 0, ttl)
                if not ok then
                    return nil, "Failed to reset used count"
                end
                return response.quota
            end
        end
        ngx.sleep(0.1)
    end
    
    return nil, "No quota available from peers"
end

-- Handle quota steal requests from other nodes
local function handle_steal_request()
    local red = redis:new()
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return
    end

    ok, err = red:subscribe(steal_request_channel)
    if not ok then
        return
    end

    while true do
        local res, err = red:read_reply()
        if res and res[1] == "message" then
            local request = cjson.decode(res[3])
            local shared_dict = ngx.shared.rate_limit_dict
            
            -- Check our local quota
            local batch_quota = shared_dict:get(request.redis_key .. ":batch") or 0
            local batch_used = shared_dict:get(request.redis_key .. ":used") or 0
            local available = batch_quota - batch_used
            
            if available > 1 then
                -- Share half of our available quota
                local share_amount = math.floor(available / 2)
                
                -- Reduce our local quota
                shared_dict:set(request.redis_key .. ":batch", batch_quota - share_amount)
                
                -- Send response
                local resp_red = redis:new()
                resp_red:connect(redis_host, redis_port)
                local response = {
                    donor_id = node_id,
                    quota = share_amount
                }
                resp_red:publish(steal_response_channel .. request.requester_id, 
                               cjson.encode(response))
                close_redis(resp_red)
            end
        end
    end
end

-- Process batch quota and update shared dictionary
local function process_batch_quota(red, shared_dict, redis_key, ttl)
    local batch_quota = shared_dict:get(redis_key .. ":batch") or 0
    local batch_used = shared_dict:get(redis_key .. ":used") or 0

    if batch_quota == 0 then
        local batch_size = fetch_batch_quota(red, redis_key)
        if not batch_size then
            return nil, "Failed to fetch batch quota"
        end

        if batch_size > 0 then
            local success, err = set_new_batch(shared_dict, redis_key, batch_size, ttl)
            if not success then
                return nil, err
            end

            return batch_size
        else
            return 0
        end
    end

    return batch_quota
end

-- Increment the used count and check if request is allowed
local function increment_and_check(shared_dict, redis_key, batch_quota, red, ttl)
    if batch_quota > 0 then
        local new_used, err = shared_dict:incr(redis_key .. ":used", 1, 0)
        if err then
            return nil, "Failed to increment used count: " .. err
        end

        if new_used <= batch_quota then
            return true
        else
            -- Check global rate limit
            local current_count, err = red:get(redis_key)
            if err then
                return nil, "Failed to GET from Redis: " .. err
            end
            current_count = tonumber(current_count) or 0

            if current_count >= rate_limit then
                -- Try to steal quota from peers when both local and global quotas are exhausted
                local stolen_quota, err = try_steal_quota(shared_dict, redis_key, ttl)
                if stolen_quota then
                    return true
                end
                return false
            end

            -- Update Redis with the exhausted batch
            local success, err = update_redis_with_exhausted_batch(red, redis_key, batch_quota, ttl)
            if not success then
                return nil, err
            end

            -- Fetch new batch quota
            local new_batch_size = fetch_batch_quota(red, redis_key)
            if new_batch_size > 0 then
                local success, err = set_new_batch(shared_dict, redis_key, new_batch_size, ttl)
                if not success then
                    return nil, err
                end

                local updated_used, err = shared_dict:incr(redis_key .. ":used", 1, 0)
                if not updated_used then
                    return nil, "Failed to increment used count after setting new batch: " .. err
                end

                return true
            else
                return false
            end
        end
    end

    return false
end

-- Rate limiting logic wrapper
local function check_rate_limit(red, token)
    -- Calculate TTL
    local ttl = calculate_ttl()

    local service_name = ngx.var.service_name
    local http_method = ngx.var.request_method

    -- Get the current timestamp and round it down to the nearest minute
    local current_time = ngx.now()
    local window_start = math.floor(current_time / window_size) * window_size

    -- Construct the Redis key using the token, http_method, service_name and the window start time
    local redis_key = string.format("rate_limit:%s:%s:%s:%d", token, http_method, service_name, window_start)

    -- Access shared dictionary
    local shared_dict, err = get_shared_dict()
    if not shared_dict then
        return nil, err
    end

    -- Acquire lock to prevent race conditions
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(redis_key, { timeout = 10 })  -- 10 seconds timeout
    if not elapsed then
        return nil, "Failed to acquire lock: " .. err
    end

    -- Ensure lock is released
    local function unlock_and_return(status, error_msg)
        local ok, err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "Failed to unlock: " .. err)
        end
        if error_msg then
            return nil, error_msg
        end
        return status
    end

    -- Process batch quota
    local batch_quota, err = process_batch_quota(red, shared_dict, redis_key, ttl)
    if not batch_quota then
        return unlock_and_return(nil, err)
    end

    -- Determine if request is allowed
    local allowed, err = increment_and_check(shared_dict, redis_key, batch_quota, red, ttl)
    if err then
        return unlock_and_return(nil, err)
    end

    -- Release the lock and return result
    return unlock_and_return(allowed and ngx.HTTP_OK or ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Main function
local function main()
    -- Initialize quota stealing worker in worker 0
    if ngx.worker.id() == 0 then
        ngx.timer.at(0, function(premature)
            if not premature then
                handle_steal_request()
            end
        end)
    end

    -- Get token
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Initialize Redis with pooling
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Use pcall to handle errors in rate limiting logic
    local res, status = pcall(check_rate_limit, red, token)
    
    -- Close Redis connection (return to pool)
    local ok, err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", err)
    end

    if not res then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif status == ngx.HTTP_TOO_MANY_REQUESTS then
        ngx.exit(status)
    end
end

-- Run the main function
main()