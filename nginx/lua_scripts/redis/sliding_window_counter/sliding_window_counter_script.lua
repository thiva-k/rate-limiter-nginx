local redis = require "resty.redis"
local cjson = require "cjson"

-- Redis configuration
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout

-- Sliding window parameters
local window_size = 15000 -- 15 seconds window in milliseconds
local subwindow_size = 3000 -- 3 seconds per subwindow in milliseconds
local max_requests = 10 -- Maximum allowed requests in the window
local subwindow_count = math.floor(window_size / subwindow_size) -- Number of subwindows


local red = redis:new()
red:set_timeout(redis_timeout)
local ok, err = red:connect(redis_host, redis_port)
if not ok then
    ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR) -- 500
end

-- Fetch and validate the token from the URL parameter
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST) -- 400
end


-- Lua script for sliding window counter
local function get_sliding_window_script()
    return [[
        local key_prefix = KEYS[1]
        local now = tonumber(ARGV[1])
        local window_size = tonumber(ARGV[2])
        local subwindow_size = tonumber(ARGV[3])
        local max_requests = tonumber(ARGV[4])
        local subwindow_count = tonumber(ARGV[5])

        local current_subwindow = math.floor(now / subwindow_size)
        local current_key = key_prefix .. ":" .. current_subwindow

        local current_count = redis.call("INCR", current_key)
        if current_count == 1 then
            redis.call("PEXPIRE", current_key, window_size)
        end

        local total_requests = 0
        for i = 0, subwindow_count - 1 do
            local subwindow_key = key_prefix .. ":" .. (current_subwindow - i)
            local subwindow_count = tonumber(redis.call("GET", subwindow_key)) or 0
            total_requests = total_requests + subwindow_count
        end

        if total_requests > max_requests then
            return 0
        else
            return 1
        end
    ]]
end

-- Function to load the script into Redis if not already cached
local function load_script_to_redis(red, script)
    local sha = ngx.shared.my_cache:get("rate_limit_script_sha")
    if not sha then
        local new_sha, err = red:script("LOAD", script)
        if not new_sha then
            ngx.log(ngx.ERR, "Failed to load script: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        ngx.shared.my_cache:set("rate_limit_script_sha", new_sha)
        sha = new_sha
    end
    return sha
end

-- Execute the sliding window logic atomically
local function execute_sliding_window(red, sha, token_key_prefix, window_size, subwindow_size, max_requests, subwindow_count)
    local now = ngx.now() * 1000 -- Current time in milliseconds
    local result, err = red:evalsha(sha, 1, token_key_prefix, now, window_size, subwindow_size, max_requests, subwindow_count)

    if err then
        if err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            ngx.shared.my_cache:delete("rate_limit_script_sha")
            sha = load_script_to_redis(red, get_sliding_window_script())
            result, err = red:evalsha(sha, 1, token_key_prefix, now, window_size, subwindow_size, max_requests, subwindow_count)
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
    -- Redis key prefix for subwindows
    local token_key_prefix = "sliding_window:" .. token

    -- Load or retrieve the Lua script SHA
    local script = get_sliding_window_script()
    local sha = load_script_to_redis(red, script)

    -- Execute sliding window logic
    local result = execute_sliding_window(red, sha, token_key_prefix, window_size, subwindow_size, max_requests, subwindow_count)

    -- Handle the result
    if result == 1 then
        ngx.say("Request allowed")
    else
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- 429 Too Many Requests
    end
end

-- Run the rate limiter
rate_limit()
