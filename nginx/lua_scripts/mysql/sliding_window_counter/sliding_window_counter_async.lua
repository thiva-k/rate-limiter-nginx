local mysql = require "resty.mysql"
local resty_lock = require "resty.lock"

local db_host = "mysql"
local db_port = 3306
local db_name = "rate_limit_db"
local db_user = "root"
local db_password = "root"

local rate_limit = 500  -- Max 500 requests per minute
local window_size = 60  -- 60 second window
local batch_percent = 0.1  -- 10% of remaining quota
local min_batch_size = 1  -- Minimum batch size

-- Connect to MySQL
local db, err = mysql:new()
if not db then
    ngx.log(ngx.ERR, "Failed to instantiate MySQL: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

db:set_timeout(1000) -- 1 second timeout
local ok, err, errcode, sqlstate = db:connect{
    host = db_host,
    port = db_port,
    database = db_name,
    user = db_user,
    password = db_password,
    charset = "utf8mb4",
    max_packet_size = 1024 * 1024,
}

if not ok then
    ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Fetch the token from the URL parameter
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

-- Initialize shared memory
local shared_dict = ngx.shared.rate_limit_dict
if not shared_dict then
    ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Function to fetch batch quota from MySQL
local function fetch_batch_quota()
    local current_time = ngx.now()  -- Current time in seconds

    -- Delete outdated requests (older than the window size)
    local delete_query = string.format("DELETE FROM rate_limit_sliding_window WHERE token = %s AND request_time < %f", 
        ngx.quote_sql_str(token), current_time - window_size)
    local res, err, errcode, sqlstate = db:query(delete_query)
    if not res then
        ngx.log(ngx.ERR, "Failed to delete old requests: ", err)
        return nil, nil
    end

    -- Count the number of requests in the current window
    local count_query = string.format("SELECT COUNT(*) as request_count FROM rate_limit_sliding_window WHERE token = %s", 
        ngx.quote_sql_str(token))
    local res, err, errcode, sqlstate = db:query(count_query)
    if not res then
        ngx.log(ngx.ERR, "Failed to count requests: ", err)
        return nil, nil
    end

    local request_count = tonumber(res[1].request_count)

    -- Calculate remaining quota and batch size
    local remaining = math.max(0, rate_limit - request_count)
    if remaining == 0 then
        return 0, window_size -- No more requests allowed in this window
    end

    local batch_size = math.floor(remaining * batch_percent)
    batch_size = math.max(math.min(batch_size, remaining), min_batch_size)

    return batch_size, window_size
end

-- Function to update MySQL with the exhausted batch
local function update_mysql_with_exhausted_batch(exhausted_batch_size)
    local current_time = ngx.now()  -- Current time in seconds

    -- Insert exhausted batch of requests into MySQL
    for i = 1, exhausted_batch_size do
        local insert_query = string.format("INSERT INTO rate_limit_sliding_window (token, request_time) VALUES (%s, %f)", 
            ngx.quote_sql_str(token), current_time)
        local res, err, errcode, sqlstate = db:query(insert_query)
        if not res then
            ngx.log(ngx.ERR, "Failed to update MySQL with exhausted batch: ", err)
            return false
        end
    end
    return true
end

-- Use a lock to ensure only one worker fetches the quota at a time
local lock = resty_lock:new("my_locks")
local elapsed, err = lock:lock(token)
if not elapsed then
    ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Check if we need to fetch a new batch quota
local batch_quota, err = shared_dict:get(token .. ":batch")
local batch_used, err_used = shared_dict:get(token .. ":used")

if not batch_quota or batch_quota == 0 or not batch_used then
    -- Update MySQL with the previously exhausted batch if it exists
    if batch_used and batch_used > 0 then
        local success = update_mysql_with_exhausted_batch(batch_used)
        if not success then
            lock:unlock()
            ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
        end
    end
    
    -- Fetch new batch quota from MySQL
    batch_quota, ttl = fetch_batch_quota()
    if batch_quota == nil then
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    
    if batch_quota > 0 then
        -- Store new batch quota in shared memory
        ok, err = shared_dict:set(token .. ":batch", batch_quota, ttl)
        if not ok then
            ngx.log(ngx.ERR, "Failed to set batch quota in shared memory: ", err)
            lock:unlock()
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        -- Reset the used count for the new batch
        ok, err = shared_dict:set(token .. ":used", 0, ttl)
        if not ok then
            ngx.log(ngx.ERR, "Failed to reset used count in shared memory: ", err)
            lock:unlock()
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    end
end

local allowed = false
if batch_quota > 0 then
    -- Increment the used count
    local new_used, err = shared_dict:incr(token .. ":used", 1, 0)
    if err then
        ngx.log(ngx.ERR, "Failed to increment used count: ", err)
        lock:unlock()
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    
    if new_used <= batch_quota then
        allowed = true
    else
        -- Batch is exhausted, update MySQL and fetch a new batch
        local success = update_mysql_with_exhausted_batch(batch_quota)
        if success then
            -- Fetch new batch quota from MySQL
            batch_quota, ttl = fetch_batch_quota()
            if batch_quota and batch_quota > 0 then
                -- Store new batch quota in shared memory
                ok, err = shared_dict:set(token .. ":batch", batch_quota, ttl)
                if not ok then
                    ngx.log(ngx.ERR, "Failed to set new batch quota in shared memory: ", err)
                    lock:unlock()
                    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
                end
                -- Reset the used count for the new batch
                ok, err = shared_dict:set(token .. ":used", 1, ttl)
                if not ok then
                    ngx.log(ngx.ERR, "Failed to reset used count in shared memory: ", err)
                    lock:unlock()
                    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
                end
                allowed = true
            end
        end
    end
end

lock:unlock()

-- Check if the request should be allowed
if not allowed then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end
