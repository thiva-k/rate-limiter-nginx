local mysql = require "resty.mysql"
local cjson = require "cjson"

-- Define the rate limiter parameters
local window_size = 15 -- Window size in seconds
local request_limit = 10 -- Max requests allowed in the window
local number_of_sub_windows = 5 -- Number of subwindows (can be adjusted for granularity)
local sub_window_size = window_size / number_of_sub_windows -- Size of each subwindow

-- Initialize MySQL connection
local db = mysql:new()
db:set_timeout(1000) -- 1 second timeout

-- Connect to MySQL
local ok, err = db:connect{
    host = "mysql",  -- Update to your MySQL host
    port = 3306,
    database = "rate_limit_db",  -- Update to your database name
    user = "root",  -- Update to your MySQL user
    password = "root",  -- Update to your MySQL password
}

if not ok then
    ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err)
    return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Function to escape strings for MySQL queries
local function escape_string(str)
    if not str then return nil end
    return str:gsub("'", "''")  -- Escape single quotes by doubling them
end

-- Function to convert MySQL DATETIME to Unix timestamp
local function datetime_to_unix(datetime_str)
    local year, month, day, hour, min, sec = datetime_str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    if year and month and day and hour and min and sec then
        return os.time({year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec)})
    end
    return nil
end

-- Function to check if the request is allowed (sliding window counter algorithm)
local function allowed(token)
    local now = ngx.now()
    local redis_key_prefix = "sliding_window_counter:" .. token

    -- Fetch the request limits for the token
    local res, err = db:query("SELECT last_access, sub_windows FROM request_limits WHERE token = '" .. escape_string(token) .. "'")
    if not res then
        ngx.log(ngx.ERR, "Failed to query MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local last_access_time
    local sub_windows

    if #res == 0 then
        -- If no record exists, initialize it
        last_access_time = now
        sub_windows = {}
        for i = 1, number_of_sub_windows do
            sub_windows[i] = 0 -- Initialize all subwindows to 0 requests
        end
        -- Insert a new record
        local insert_query = "INSERT INTO request_limits (token, last_access, sub_windows) VALUES ('" .. escape_string(token) .. "', FROM_UNIXTIME(" .. now .. "), '" .. cjson.encode(sub_windows) .. "')"
        local insert_res, insert_err = db:query(insert_query)
        if not insert_res then
            ngx.log(ngx.ERR, "Failed to insert new record in MySQL: ", insert_err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    else
        last_access_time = res[1].last_access  -- This will be a string in DATETIME format
        last_access_time = datetime_to_unix(last_access_time)  -- Convert to Unix timestamp
        sub_windows = cjson.decode(res[1].sub_windows) -- Decode the JSON stored array
    end

    -- Calculate elapsed time since the last access
    local elapsed_time = now - last_access_time

    -- Initialize the subwindows if they don't exist
    if not sub_windows or #sub_windows == 0 then
        sub_windows = {}
        for i = 1, number_of_sub_windows do
            sub_windows[i] = 0 -- Initialize all subwindows to 0 requests
        end
    end

    -- Update subwindow count if the elapsed time exceeds the subwindow size
    if elapsed_time >= sub_window_size then
        local current_sub_window_index = math.floor(now / sub_window_size) % number_of_sub_windows
        sub_windows[current_sub_window_index + 1] = 0 -- Reset the current subwindow count
    end

    -- Calculate the total requests in the sliding window
    local total_requests = 0
    for _, count in ipairs(sub_windows) do
        total_requests = total_requests + count
    end

    -- Check if the total requests exceed the limit
    if total_requests < request_limit then
        -- Increment the count for the current subwindow
        local current_sub_window_index = math.floor(now / sub_window_size) % number_of_sub_windows
        sub_windows[current_sub_window_index + 1] = sub_windows[current_sub_window_index + 1] + 1
        
        -- Update the subwindows in MySQL
        local update_query = "UPDATE request_limits SET sub_windows = '" .. cjson.encode(sub_windows) .. "', last_access = FROM_UNIXTIME(" .. now .. ") WHERE token = '" .. escape_string(token) .. "'"
        local update_res, update_err = db:query(update_query)
        if not update_res then
            ngx.log(ngx.ERR, "Failed to update sub windows in MySQL: ", update_err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        return true -- Request allowed
    else
        return false -- Request not allowed
    end
end

-- Example usage: Fetch token from URL parameters and check if the request is allowed
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

if allowed(token) then
    ngx.say("Request allowed")
else
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) -- Return 429 if rate limit exceeded
end
