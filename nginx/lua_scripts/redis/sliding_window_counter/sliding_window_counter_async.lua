local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local window_size = 60 -- Total window size in seconds
local request_limit = 5 -- Max requests allowed in the window
local sub_window_count = 3 -- Number of subwindows
local sub_window_size = window_size / sub_window_count -- Size of each subwindow
local batch_percent = 0.5 -- Percentage of remaining quota to allocate for batch

-- Lua scripts
local fetch_counts_script = [[
local key_prefix = KEYS[1]
local current_window = tonumber(ARGV[1])
local sub_window_count = tonumber(ARGV[2])
local sub_window_size = tonumber(ARGV[3])
local now = tonumber(ARGV[4])

local total = 0

for i = 0, sub_window_count do
    local window_key = key_prefix .. ":" .. (current_window - i*sub_window_size)
    local count = redis.call('get', window_key)
    count = count and tonumber(count) or 0
    
    if i == sub_window_count then
        local elapsed_in_window = now % sub_window_size
        local weight = (sub_window_size - elapsed_in_window) / sub_window_size
        total = total + (count * weight)
    else
        total = total + count
    end
end

return total
]]

local update_counts_script = [[
local key_prefix = KEYS[1]
local current_window = tonumber(ARGV[1])
local sub_window_size = tonumber(ARGV[2])
local updates = cjson.decode(ARGV[3])

for window_offset, count in pairs(updates) do
    local window_key = key_prefix .. ":" .. (current_window - window_offset * sub_window_size)
    if tonumber(count) > 0 then
        redis.call('incrby', window_key, count)
        redis.call('expire', window_key, 3600) -- Added expiration for safety
    end
end

return true
]]

-- Helper function to get script SHA
local function get_script_sha(red, script_name, script_content)
    local sha = ngx.shared.my_cache:get(script_name)
    if not sha then
        local new_sha, err = red:script("LOAD", script_content)
        if not new_sha then
            return nil, "Failed to load script: " .. err
        end
        ngx.shared.my_cache:set(script_name, new_sha)
        sha = new_sha
    end
    return sha
end

-- Initialize Redis connection
local function init_redis()
    local red = redis:new()
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, "Failed to connect to Redis: " .. err
    end
    return red
end

-- Close Redis connection
local function close_redis(red)
    local ok, err = red:set_keepalive(max_idle_timeout, pool_size)
    if not ok then
        return nil, err
    end
    return true
end

-- Helper function to get URL token
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Get the current window and timestamp
local function get_current_window()
    local now = ngx.now()
    local current_window = math.floor(now / sub_window_size) * sub_window_size
    return current_window, now
end

-- Function to fetch current total from Redis using Lua script
local function fetch_window_total(red, key_prefix, current_window, now)
    -- Get the script SHA
    local sha, err = get_script_sha(red, "fetch_counts_script", fetch_counts_script)
    if not sha then
        return nil, err
    end
    
    -- Execute the script
    local result, err = red:evalsha(
        sha,
        1, -- number of keys
        key_prefix, -- KEYS[1]
        current_window, -- ARGV[1]
        sub_window_count, -- ARGV[2]
        sub_window_size, -- ARGV[3]
        now -- ARGV[4]
    )
    
    if err then
        if err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            ngx.shared.my_cache:delete("fetch_counts_script")
            sha, err = get_script_sha(red, "fetch_counts_script", fetch_counts_script)
            if not sha then
                return nil, err
            end
            result, err = red:evalsha(sha, 1, key_prefix, current_window, sub_window_count, sub_window_size, now)
        end
        
        if err then
            return nil, "Failed to execute fetch_counts script: " .. err
        end
    end
    
    return result
end

-- Function to calculate and fetch batch quota
local function fetch_batch_quota(red, key_prefix, current_window, now)
    local total, err = fetch_window_total(red, key_prefix, current_window, now)
    if not total then
        return 0, err
    end
    
    local remaining = math.max(0, request_limit - total)
    return math.ceil(remaining * batch_percent)
end

-- Initialize or get shared dictionary for local counting
local function get_shared_dict()
    local dict = ngx.shared.rate_limit_dict
    if not dict then
        return nil, "Failed to get shared dictionary"
    end
    return dict
end

-- Update Redis with accumulated counts using Lua script
local function update_redis_counts(red, key_prefix, shared_dict, current_window)
    local updates = {}
    
    -- Collect all non-zero counts
    for i = 0, sub_window_count do
        local window_key = key_prefix .. ":" .. (current_window - i * sub_window_size)
        local local_count = shared_dict:get(window_key .. ":local") or 0
        if local_count > 0 then
            updates[tostring(i)] = local_count
            shared_dict:set(window_key .. ":local", 0)
        end
    end
    
    -- Only make the Redis call if we have updates
    if next(updates) then
        local cjson = require "cjson"
        
        -- Get the script SHA
        local sha, err = get_script_sha(red, "update_counts_script", update_counts_script)
        if not sha then
            return nil, err
        end
        
        -- Execute the script
        local ok, err = red:evalsha(
            sha,
            1, -- number of keys
            key_prefix, -- KEYS[1]
            current_window, -- ARGV[1]
            sub_window_size, -- ARGV[2] (now passing sub_window_size instead of window_size)
            cjson.encode(updates) -- ARGV[3]
        )
        
        if err then
            if err:find("NOSCRIPT", 1, true) then
                -- Script not found in Redis, reload it
                ngx.shared.my_cache:delete("update_counts_script")
                sha, err = get_script_sha(red, "update_counts_script", update_counts_script)
                if not sha then
                    return nil, err
                end
                ok, err = red:evalsha(sha, 1, key_prefix, current_window, sub_window_size, cjson.encode(updates))
            end
            
            if err then
                return nil, "Failed to execute update_counts script: " .. err
            end
        end
    end
    
    return true
end

-- Process batch quota including potential refresh from Redis
local function process_batch_quota(red, key_prefix, shared_dict, current_window, now)
    local batch_key = key_prefix .. ":batch"
    local batch_quota = shared_dict:get(batch_key)
    
    if not batch_quota or batch_quota <= 0 then
        local new_quota, err = fetch_batch_quota(red, key_prefix, current_window, now)
        if err then
            return nil, err
        end
        if new_quota > 0 then
            shared_dict:set(batch_key, new_quota, window_size)
            return new_quota
        else
            return 0
        end
    end
    
    return batch_quota
end

-- Main rate limiting logic
local function check_rate_limit(red, token, current_window, now)
    local shared_dict, err = get_shared_dict()
    if not shared_dict then
        return nil, err
    end

    local key_prefix = "rate_limit:" .. token
    
    -- Acquire lock for consistency
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(key_prefix)
    if not elapsed then
        return nil, "Failed to acquire lock: " .. err
    end

    -- Ensure lock is released
    local function unlock_and_return(status, error_msg)
        local ok, err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "Failed to unlock: ", err)
        end
        if error_msg then
            return nil, error_msg
        end
        return status
    end

    -- Get batch quota
    local batch_quota, err = process_batch_quota(red, key_prefix, shared_dict, current_window, now)
    if err then
        return unlock_and_return(nil, err)
    end
    if batch_quota <= 0 then
        return unlock_and_return(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    -- Increment local counter for current subwindow
    local window_key = key_prefix .. ":" .. current_window
    local local_key = window_key .. ":local"
    local new_count = shared_dict:incr(local_key, 1, 0)
    
    -- Decrement batch quota
    local remaining_quota = shared_dict:incr(key_prefix .. ":batch", -1, 0)
    
    -- If batch is exhausted, update Redis
    if remaining_quota <= 0 then
        local ok, err = update_redis_counts(red, key_prefix, shared_dict, current_window)
        if not ok then
            return unlock_and_return(nil, err)
        end
    end

    return unlock_and_return(ngx.HTTP_OK)
end

-- Main function
local function main()
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local current_window, now = get_current_window()
    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local success, status, err = pcall(check_rate_limit, red, token, current_window, now)
    local ok, close_err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", close_err)
    end

    if not success then
        ngx.log(ngx.ERR, status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif err then
        ngx.log(ngx.ERR, err)
        ngx.exit(status)
    elseif status == ngx.HTTP_TOO_MANY_REQUESTS then
        ngx.exit(status)
    end
end

-- Run the main function
main()