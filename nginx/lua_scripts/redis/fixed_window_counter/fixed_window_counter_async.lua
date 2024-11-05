local redis = require "resty.redis"
local resty_lock = require "resty.lock"
local cjson = require "cjson"

-- Configuration
local redis_host = "redis"         -- Redis server host
local redis_port = 6379            -- Redis server port
local redis_timeout = 1000         -- 1 second timeout
local max_idle_timeout = 10000     -- 10 seconds
local pool_size = 100             -- Maximum number of idle connections in the pool
local rate_limit = 10             -- Max requests allowed in the window
local batch_percent = 0.1          -- Percentage of remaining requests to allow in a batch
local min_batch_size = 1           -- Minimum size of batch
local window_size = 60             -- Time window size in seconds

-- Quota stealing configuration
local node_id = os.getenv("NODE_ID") or ngx.worker.pid()
local steal_request_channel = "quota_steal_requests"
local steal_offer_channel = "quota_steal_offers:"
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

-- Fetch batch quota from Redis and update Redis count
local function fetch_and_update_batch_quota(red, redis_key, ttl)
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


    local new_count, err = red:incrby(redis_key, batch_size)
    if err then
        return nil, "Failed to INCRBY in Redis: " .. err
    end

    if new_count == batch_size then  -- Set TTL only on the initial increment
        red:expire(redis_key, ttl)
    end

    return batch_size
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
    
    local ok, err = red:publish(steal_request_channel, cjson.encode(request))
    if not ok then
        red:close()
        return nil, "Failed to publish steal request"
    end

    -- Subscribe to offers channel
    local ok, err = red:subscribe(steal_offer_channel .. node_id)
    if not ok then
        red:close()
        return nil, "Failed to subscribe to offer channel"
    end

    -- Collect offers for a short time
    local offers = {}
    local start_time = ngx.now()
    while (ngx.now() - start_time) < steal_timeout do
        local res, err = red:read_reply(100)  -- 100ms timeout
        if res and res[1] == "message" then
            local success, offer = pcall(cjson.decode, res[3])
            if success and offer and type(offer) == "table" and offer.quota and offer.donor_id then
                offers[#offers + 1] = offer
            end
        end
    end

    -- Unsubscribe before proceeding
    local ok, err = red:unsubscribe()
    if not ok then
        ngx.log(ngx.ERR, "Failed to unsubscribe: " .. err)
    end

    -- If we got offers, select the best one
    if #offers > 0 then
        -- Sort offers by quota size (descending)
        table.sort(offers, function(a, b) return a.quota > b.quota end)
        local chosen_offer = offers[1]
        
        -- Send acceptance to chosen donor
        local accept_red = redis:new()
        local ok, err = accept_red:connect(redis_host, redis_port)
        if not ok then
            return nil, "Failed to connect to Redis for acceptance"
        end
        
        ok, err = accept_red:publish("quota_accept:" .. chosen_offer.donor_id, 
                                   cjson.encode({accepted = true}))
        if not ok then
            accept_red:close()
            return nil, "Failed to publish acceptance"
        end
        
        accept_red:set_keepalive(max_idle_timeout, pool_size)

        -- Update our local batch quota
        ok, err = shared_dict:set(redis_key .. ":batch", chosen_offer.quota, ttl)
        if not ok then
            return nil, "Failed to set stolen quota"
        end
        
        -- Reset used count
        ok, err = shared_dict:set(redis_key .. ":used", 0, ttl)
        if not ok then
            return nil, "Failed to reset used count"
        end
        
        return chosen_offer.quota
    end
    
    red:close()
    return nil, "No quota available from peers"
end

-- Process batch quota and update shared dictionary
local function process_batch_quota(red, shared_dict, redis_key, ttl)
    local batch_quota = shared_dict:get(redis_key .. ":batch") or 0

    if batch_quota == 0 then
        local batch_size, err = fetch_and_update_batch_quota(red, redis_key, ttl)
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


            local new_batch_size, err = fetch_and_update_batch_quota(red, redis_key, ttl)
            if not new_batch_size then
                return nil, err
            end

            if new_batch_size > 0 then
                local success, err = set_new_batch(shared_dict, redis_key, new_batch_size, ttl)
                if not success then
                    return nil, err
                end

                --Incrment only once for this request
                local updated_used, err = shared_dict:incr(redis_key .. ":used", 1, 0)

                if not updated_used then
                   return nil, "Failed to increment used count after setting new batch: "..err
                end

                return true
            else
                return false -- No batch quota available
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