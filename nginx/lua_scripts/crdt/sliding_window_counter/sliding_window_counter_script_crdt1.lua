local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis-enterprise-1"
local redis_port = 12000
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local window_size = 60 -- Total window size in seconds
local request_limit = 100 -- Max requests allowed in the window
local sub_window_count = 4 -- Number of subwindows

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
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Helper function to get script SHA
local function get_script_sha(red)
    local sha = ngx.shared.my_cache:get("rate_limit_script_sha")
    if not sha then
        local redis_script = [[
            local key_prefix = KEYS[1]
            local window_size = tonumber(ARGV[1])
            local request_limit = tonumber(ARGV[2])
            local sub_window_count = tonumber(ARGV[3])

            -- Get current time and calculate sub-window parameters
            local time = redis.call('TIME')
            local now = tonumber(time[1])
            local sub_window_size = window_size / sub_window_count
            local current_window_key = math.floor(now / sub_window_size) * sub_window_size
            local elapsed_time = now % sub_window_size

            -- Get current window count
            local current_key = key_prefix .. current_window_key
            local current_count = tonumber(redis.call('GET', current_key) or 0)

            -- Calculate total requests across all subwindows
            local total_requests = current_count

            for i = 1, sub_window_count do
                local previous_window_key = current_window_key - (i * sub_window_size)
                local previous_key = key_prefix .. previous_window_key
                local previous_count = tonumber(redis.call('GET', previous_key) or 0)

                -- Apply weight for the oldest window
                if i == sub_window_count then
                    total_requests = total_requests + ((sub_window_size - elapsed_time) / sub_window_size) * previous_count
                else
                    total_requests = total_requests + previous_count
                end
            end

            -- Check if the request limit is exceeded
            if total_requests + 1 > request_limit then
                return 1
            end

            -- Increment the count for the current window
            redis.call('INCR', current_key)
            redis.call('EXPIRE', current_key, window_size)

            return 0
        ]]
        local new_sha, err = red:script("LOAD", redis_script)
        if not new_sha then
            return nil, "Failed to load script: " .. err
        end
        ngx.shared.my_cache:set("rate_limit_script_sha", new_sha)
        sha = new_sha
    end
    return sha
end

-- Main rate limiting logic
local function check_rate_limit(red, token)
    -- Get the script SHA
    local sha, err = get_script_sha(red)
    if not sha then
        return ngx.HTTP_INTERNAL_SERVER_ERROR, err
    end

    -- Construct the Redis key prefix using the token
    local key_prefix = "rate_limit:{" .. token .. "}"

    -- Run the Lua script
    local result, err = red:evalsha(sha, 1, key_prefix, window_size, request_limit, sub_window_count)

    if err then
        if err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            ngx.shared.my_cache:delete("rate_limit_script_sha")
            sha, err = get_script_sha(red)
            if not sha then
                return ngx.HTTP_INTERNAL_SERVER_ERROR, err
            end
            result, err = red:evalsha(sha, 1, key_prefix, window_size, request_limit, sub_window_count)
        end

        if err then
            return ngx.HTTP_INTERNAL_SERVER_ERROR, "Failed to run rate limiting script: " .. err
        end
    end

    if result == 1 then
        return ngx.HTTP_TOO_MANY_REQUESTS
    end

    return ngx.HTTP_OK
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local success, status, err = pcall(check_rate_limit, red, token)
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