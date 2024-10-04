local mysql = require "resty.mysql"

-- MySQL configuration
local mysql_host = "mysql"
local mysql_port = 3306
local mysql_user = "root"
local mysql_password = "root"
local mysql_database = "rate_limit_db" -- Your database name

local function init_mysql()
    local db, err = mysql:new()
    if not db then
        ngx.log(ngx.ERR, "Failed to instantiate MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    db:set_timeout(1000) -- 1 second timeout

    local ok, err, errcode, sqlstate = db:connect{
        host = mysql_host,
        port = mysql_port,
        user = mysql_user,
        password = mysql_password,
        database = mysql_database
    }

    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    return db
end


-- Define the rate limiter parameters
local max_count = 15 -- Max requests allowed in the window
local window_length_secs = 10 -- Window size in seconds
local granularity = 1 -- Size of each small interval in seconds

-- Function to get the current time in seconds
local function get_current_time_secs()
    return ngx.now()
end

-- Function to check if the request is allowed (sliding window counter algorithm)
local function allowed(token)
    local db = init_mysql()

    -- Get the current time and calculate the current time bucket
    local now = get_current_time_secs()
    local current_bucket = math.floor(now / granularity)

    -- Calculate the range of buckets that fall within the sliding window
    local min_bucket = current_bucket - math.floor(window_length_secs / granularity)

    -- Query to sum the requests from relevant buckets in the sliding window
    local query = string.format([[
        SELECT SUM(request_count) AS total_requests
        FROM sliding_window_counter
        WHERE token = '%s' AND bucket BETWEEN %d AND %d
    ]], token, min_bucket, current_bucket)

    -- Execute the query to get the total number of requests in the current window
    local res, err, errcode, sqlstate = db:query(query)
    if not res then
        ngx.log(ngx.ERR, "Failed to query MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local total_requests = tonumber(res[1].total_requests) or 0

    -- Check if the number of requests exceeds the rate limit
    if total_requests >= max_count then
        -- Too many requests in the current window, reject
        return false
    else
        -- Increment the counter for the current bucket
        local insert_query = string.format([[
            INSERT INTO sliding_window_counter (token, bucket, request_count)
            VALUES ('%s', %d, 1)
            ON DUPLICATE KEY UPDATE request_count = request_count + 1
        ]], token, current_bucket)

        local res, err, errcode, sqlstate = db:query(insert_query)
        if not res then
            ngx.log(ngx.ERR, "Failed to insert/update request count: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        -- Optionally, cleanup old records (buckets) outside the sliding window
        local cleanup_query = string.format([[
            DELETE FROM sliding_window_counter WHERE bucket < %d
        ]], min_bucket)

        db:query(cleanup_query)

        return true
    end
end

-- Fetch token from URL parameters and check if the request is allowed
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

if allowed(token) then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end
