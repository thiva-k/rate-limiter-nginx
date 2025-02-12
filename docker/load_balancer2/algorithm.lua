local mysql = require "resty.mysql"

-- MySQL connection settings
local mysql_host = "mysql"
local mysql_port = 3306
local mysql_user = "root"
local mysql_password = "root"
local mysql_database = "rate_limit_db"
local mysql_timeout = 3000 -- 3 second
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Leaky bucket parameters
local max_delay = 3000 -- 3 second,
local leak_rate = 1 -- Requests leaked per second

-- Helper function to initialize MySQL connection
local function init_mysql()
    local db, err = mysql:new()
    if not db then
        return nil, err
    end

    db:set_timeout(mysql_timeout)

    local ok, err, errcode, sqlstate = db:connect{
        host = mysql_host,
        port = mysql_port,
        user = mysql_user,
        password = mysql_password,
        database = mysql_database
    }
    if not ok then
        return nil, err
    end

    return db
end

-- Helper function to close MySQL connection
local function close_mysql(db)
    local ok, err = db:set_keepalive(max_idle_timeout, pool_size)
    if not ok then
        return nil, err
    end

    return true
end

-- Helper function to get URL token
local function get_request_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Main rate-limiting logic using the leaky bucket stored procedure
local function rate_limit(db, token)
    -- Calculate bucket capacity based on max delay and leak rate
    local bucket_capacity = math.floor(max_delay / 1000 * leak_rate)

    local query = string.format([[
        CALL rate_limit(%s, %d, %d, @delay)
    ]], ngx.quote_sql_str(token), bucket_capacity, leak_rate)

    local res, err, errcode, sqlstate = db:query(query)
    if not res then
        return nil, "Failed to execute stored procedure: " .. err
    end

    local res, err, errcode, sqlstate = db:query("SELECT @delay")
    if not res then
        return nil, "Failed to get stored procedure result: " .. err
    end

    local result = tonumber(res[1]["@delay"])

    if result == -1 then
        return true, "rejected"
    else
        -- TODO: simplify using math.ceil
        local delay = math.floor(result / 1000 + 0.5) / 1000 -- Round to 3 decimal places
        return true, "allowed", delay
    end
end

-- Main function to initialize MySQL and handle rate limiting
local function main()
    local token, err = get_request_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local db, err = init_mysql()
    if not db then
        ngx.log(ngx.ERR, "Failed to initialize MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local pcall_status, rate_limit_result, message, delay = pcall(rate_limit, db, token)

    local ok, err = close_mysql(db)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close MySQL connection: ", err)
    end

    if not pcall_status then
        ngx.log(ngx.ERR, rate_limit_result)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if not rate_limit_result then
        ngx.log(ngx.ERR, "Failed to rate limit: ", message)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if message == "rejected" then
        ngx.log(ngx.INFO, "Rate limit exceeded for token: ", token)
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    else
        ngx.sleep(delay)
        ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
    end
end

-- Run the main function
main()
