local mysql = require "resty.mysql"

-- MySQL connection settings
local mysql_host = "mysql"
local mysql_port = 3306
local mysql_user = "root"
local mysql_password = "root"
local mysql_database = "rate_limit_db"
local mysql_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 50 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local rate_limit = 5
local window_size = 60 -- 60-second window

-- Helper function to initialize MySQL connection
local function init_mysql()
    local db, err = mysql:new()
    if not db then
        return nil, "Failed to instantiate MySQL: " .. (err or "unknown error")
    end

    db:set_timeout(mysql_timeout)

    local ok, err, errno, sqlstate = db:connect{
        host = mysql_host,
        port = mysql_port,
        user = mysql_user,
        password = mysql_password,
        database = mysql_database
    }

    if not ok then
        return nil, "Failed to connect to MySQL: " .. (err or "unknown error")
    end

    return db
end

-- Helper function to close MySQL connection
local function close_mysql(db)
    -- Consume any remaining result sets
    local res, err = db:read_result()
    while err == "again" do
        res, err = db:read_result()
    end
    -- Set the connection to keepalive or close it
    local ok, err = db:set_keepalive(max_idle_timeout, pool_size)
    if not ok then
        return nil, "Failed to set keepalive for MySQL connection: " .. (err or "unknown error")
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

-- Main rate limiting logic
local function check_rate_limit(db, token)
    local query = string.format(
        "CALL check_sliding_window_limit('%s', %d, %d);",
        token, window_size, rate_limit
    )
    
    local res, err = db:query(query)
    if not res then
        return ngx.HTTP_INTERNAL_SERVER_ERROR, "Failed to execute procedure: " .. (err or "unknown error")
    end
    
    if #res == 0 then
        return ngx.HTTP_INTERNAL_SERVER_ERROR, "No result returned from procedure"
    end
    
    local is_limited = tonumber(res[1].is_limited)    
    if is_limited == 1 then
        return ngx.HTTP_TOO_MANY_REQUESTS
    else
        return ngx.HTTP_OK
    end
end

-- Main function to initialize MySQL and handle rate limiting
local function main()
    local token, err = get_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local db, err = init_mysql()
    if not db then
        ngx.log(ngx.ERR, "Failed to initialize MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local status, err
    local success = pcall(function()
        status, err = check_rate_limit(db, token)
    end)

    local ok, close_err = close_mysql(db)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close MySQL connection: ", close_err)
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
