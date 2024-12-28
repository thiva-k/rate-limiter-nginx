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

local window_size = 60 -- Total window size in seconds
local request_limit = 10 -- Max allowed requests
local sub_window_count = 4 -- Number of subwindows

-- Connect to MySQL
local function connect_to_mysql()
    local db, err = mysql:new()
    if not db then
        ngx.log(ngx.ERR, "Failed to create mysql object: ", err)
        return nil, err
    end

    db:set_timeout(1000) -- 1 second timeout

    local ok, err, errno, sqlstate = db:connect(db_config)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err, " errno: ", errno, " sqlstate: ", sqlstate)
        return nil, err
    end

    return db
end

-- Main rate-limiting logic
local function rate_limit()
    -- Get the token from the request
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        ngx.log(ngx.DEBUG, "\n")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    ngx.log(ngx.DEBUG, "Token received: ", token)

    -- Calculate the current subwindow
    local now = ngx.time()
    local sub_window_size = window_size / sub_window_count
    local current_subwindow = math.floor(now / sub_window_size) * sub_window_size

    ngx.log(ngx.DEBUG, "Current subwindow calculated: ", current_subwindow)

    -- Connect to MySQL
    local db, err = connect_to_mysql()
    if not db then
        ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err)
        ngx.log(ngx.DEBUG, "\n")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Call the stored procedure
    local query = string.format(
        "CALL rate_limit_check(%s, %d, %d, %d, %d, @result); SELECT @result AS result;",
        ngx.quote_sql_str(token), current_subwindow, window_size, sub_window_count, request_limit
    )

    ngx.log(ngx.DEBUG, "Executing query: ", query)

    -- Execute the query
    local res, err, errno, sqlstate = db:query(query)

    -- Check for query execution errors
    if not res then
        ngx.log(ngx.ERR, "Failed to execute rate limit check: ", err, " errno: ", errno, " sqlstate: ", sqlstate)
        ngx.log(ngx.DEBUG, "\n")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    ngx.log(ngx.DEBUG, "Query executed successfully")

    -- Advance the cursor to the second result set (for SELECT @result AS result)
    local result_res, err = db:read_result()

    -- Check for errors in fetching the result
    if not result_res then
        ngx.log(ngx.ERR, "Failed to fetch @result: ", err)
        ngx.log(ngx.DEBUG, "\n")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Extract the result from the fetched data
    local result = result_res[1] and result_res[1].result

    if not result then
        ngx.log(ngx.ERR, "No result found for @result; possible stored procedure issue")
        ngx.log(ngx.DEBUG, "\n")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    ngx.log(ngx.DEBUG, "Rate limit check result: ", result)

    -- Check the result and act accordingly
    if tonumber(result) == 1 then
        ngx.log(ngx.DEBUG, "Request allowed for token: ", token)
        ngx.log(ngx.DEBUG, "\n")
        ngx.say("Request allowed")
        ngx.exit(ngx.HTTP_OK)
    else
        ngx.log(ngx.ERR, "Rate limit exceeded for token: ", token)
        ngx.log(ngx.DEBUG, "\n")
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
    ngx.log(ngx.DEBUG, "\n")
end

-- Execute the rate limiter
rate_limit()
