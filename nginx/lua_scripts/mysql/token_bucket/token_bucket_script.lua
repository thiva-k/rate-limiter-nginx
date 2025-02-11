local mysql = require "resty.mysql"

-- MySQL connection settings
local mysql_host = "mysql"
local mysql_port = 3306
local mysql_user = "root"
local mysql_password = "root"
local mysql_database = "rate_limit_db"
local mysql_timeout = 1000 -- 1 second
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Token bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local refill_rate = 1 -- Tokens generated per second
local requested_tokens = 1 -- Number of tokens required per request

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

-- Main rate limiting logic using stored procedure
local function rate_limit(db, token)
    local query = string.format([[
        CALL rate_limit(%s, %d, %f, %d, @result)
    ]], ngx.quote_sql_str(token), bucket_capacity, refill_rate, requested_tokens)

    local res, err, errcode, sqlstate = db:query(query)
    if not res then
        return nil, "Failed to execute stored procedure: " .. err
    end

    local res, err, errcode, sqlstate = db:query("SELECT @result")
    if not res then
        return nil, "Failed to get stored procedure result: " .. err
    end

    local rate_limit_result = tonumber(res[1]["@result"])

    if rate_limit_result == 1 then
        return true, "allowed"
    else
        return true, "rejected"
    end
end

-- Main function to handle rate limiting
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

    local pcall_status, rate_limit_result, message = pcall(rate_limit, db, token)

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
        ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
    end
end

-- Run the main function
main()
