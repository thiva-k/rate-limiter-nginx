local mysql = require "resty.mysql"

-- MySQL connection settings
local db_config = {
    host = "mysql",
    port = 3306,
    database = "rate_limit_db",
    user = "root",
    password = "root",
    charset = "utf8",
    max_packet_size = 1024 * 1024
}

local window_size = 60 -- seconds
local request_limit = 10
local sub_window_count = 12

-- Initialize MySQL connection
local function connect_to_mysql()
    ngx.log(ngx.DEBUG, "Initializing MySQL connection")
    local db, err = mysql:new()
    if not db then
        ngx.log(ngx.ERR, "Failed to create MySQL object: ", err)
        return nil, err
    end

    db:set_timeout(1000) -- 1 second timeout

    local ok, err, errno, sqlstate = db:connect(db_config)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err, " errno: ", errno, " sqlstate: ", sqlstate)
        return nil, err
    end
    ngx.log(ngx.DEBUG, "MySQL connection established")
    return db
end

-- Close MySQL connection
local function close_mysql_connection(db)
    if not db then
        return
    end
    ngx.log(ngx.DEBUG, "Closing MySQL connection")
    local ok, err = db:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set MySQL connection keepalive: ", err)
        db:close() -- Ensure the connection is closed if keepalive fails
    end
    ngx.log(ngx.DEBUG, "MySQL connection closed or set to keepalive")
end

-- Get the total requests in the sliding window
local function get_total_requests(db, token, current_subwindow, sub_window_size)
    ngx.log(ngx.DEBUG, "Fetching total requests for token: ", token)
    local start_subwindow = current_subwindow - (sub_window_count - 1) * sub_window_size

    local query = string.format([[ 
        SELECT subwindow, request_count
        FROM rate_limit_requests
        WHERE token = %s AND subwindow >= %d;
    ]], ngx.quote_sql_str(token), start_subwindow)

    ngx.log(ngx.DEBUG, "Executing query to fetch requests: \n", query)
    local res, err, errno, sqlstate = db:query(query)
    if not res then
        ngx.log(ngx.ERR, "Failed to query sliding window: ", err, " errno: ", errno, " sqlstate: ", sqlstate)
        return nil, err
    end

    local total_requests = 0
    local elapsed_time = ngx.time() % sub_window_size

    for _, row in ipairs(res) do
        local subwindow = tonumber(row.subwindow)
        local count = tonumber(row.request_count)

        if subwindow == start_subwindow then
            total_requests = total_requests + math.ceil(((sub_window_size - elapsed_time) / sub_window_size) * count)
        else
            total_requests = total_requests + count
        end
        ngx.log(ngx.DEBUG, "Subwindow: ", subwindow, ", Count: ", count, ", Total requests: ", total_requests)
    end

    ngx.log(ngx.DEBUG, "Total requests calculated: ", total_requests)
    return total_requests
end

-- Increment the current subwindow count
local function increment_subwindow(db, token, current_subwindow)
    ngx.log(ngx.DEBUG, "Incrementing request count for token: ", token, " in subwindow: ", current_subwindow)

    local query = string.format([[ 
        INSERT INTO rate_limit_requests (token, subwindow, request_count)
        VALUES (%s, %d, 1)
        ON DUPLICATE KEY UPDATE request_count = request_count + 1;
    ]], ngx.quote_sql_str(token), current_subwindow)

    ngx.log(ngx.DEBUG, "Executing query to increment subwindow: \n", query)
    local res, err, errno, sqlstate = db:query(query)
    if not res then
        ngx.log(ngx.ERR, "Failed to increment subwindow count: ", err, " errno: ", errno, " sqlstate: ", sqlstate)
        return nil, err
    end

    ngx.log(ngx.DEBUG, "Successfully incremented request count for subwindow: ", current_subwindow)
    return true
end

-- Main rate-limiting logic
local function rate_limit()
    ngx.log(ngx.DEBUG, "Starting rate limit check")
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    ngx.log(ngx.DEBUG, "Token received: ", token)
    local db, err = connect_to_mysql()
    if not db then
        ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local now = ngx.time()
    local sub_window_size = window_size / sub_window_count
    local current_subwindow = math.floor(now / sub_window_size) * sub_window_size

    ngx.log(ngx.DEBUG, "Current subwindow calculated: ", current_subwindow)

    local total_requests, err = get_total_requests(db, token, current_subwindow, sub_window_size)
    if not total_requests then
        ngx.log(ngx.ERR, "Failed to calculate total requests: ", err)
        close_mysql_connection(db)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    ngx.log(ngx.DEBUG, "Total requests so far: ", total_requests)

    if total_requests + 1 > request_limit then
        ngx.log(ngx.ERR, "Request limit exceeded for token: ", token)
        close_mysql_connection(db)
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    local success, err = increment_subwindow(db, token, current_subwindow)
    if not success then
        ngx.log(ngx.ERR, "Failed to increment subwindow: ", err)
        close_mysql_connection(db)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    ngx.log(ngx.DEBUG, "Request allowed for token: ", token)
    ngx.say("Request allowed")
    close_mysql_connection(db)
end

rate_limit()
