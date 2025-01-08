local mysql = require "resty.mysql"

-- MySQL connection settings
local mysql_config = {
    host = "mysql",
    port = 3306,
    database = "rate_limit_db",
    user = "root",
    password = "root",
    charset = "utf8mb4",
    max_packet_size = 1024 * 1024,
}

-- Token bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local refill_rate = 1 -- Tokens generated per second
local requested_tokens = 1 -- Number of tokens required per request

-- Helper function to initialize MySQL connection
local function init_mysql()
    local db, err = mysql:new()
    if not db then
        ngx.log(ngx.ERR, "Failed to create MySQL object: ", err)
        return nil, err
    end

    db:set_timeout(1000) -- 1-second timeout

    local ok, err, errcode, sqlstate = db:connect(mysql_config)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err)
        return nil, err
    end

    return db
end

-- Helper function to close MySQL connection
local function close_mysql(db)
    local ok, err = db:set_keepalive(10000, 100) -- 10 seconds, 100 connections
    if not ok then
        ngx.log(ngx.ERR, "Failed to set MySQL keepalive: ", err)
        return nil, err
    end

    return true
end

-- Helper function to get URL token
local function get_user_url_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Main rate limiting logic using stored procedure
local function rate_limit(db, token)
    local query = string.format([[
        CALL rate_limit(%s, %d, %f, %d, @allowed)
    ]], ngx.quote_sql_str(token), bucket_capacity, refill_rate, requested_tokens)

    ngx.log(ngx.DEBUG, "Executing stored procedure: ", query)
    local res, err, errcode, sqlstate = db:query(query)
    if not res then
        ngx.log(ngx.ERR, "Failed to execute stored procedure: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Fetch the result
    local allowed_res = db:query("SELECT @allowed AS allowed")
    if not allowed_res then
        ngx.log(ngx.ERR, "Failed to fetch stored procedure result")
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    local allowed = tonumber(allowed_res[1].allowed)
    if allowed == 1 then
        ngx.say("Request allowed")
        return ngx.HTTP_OK
    else
        ngx.say("Rate limit exceeded")
        return ngx.HTTP_TOO_MANY_REQUESTS
    end
end

-- Main function to handle rate limiting
local function main()
    local token, err = get_user_url_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local db, err = init_mysql()
    if not db then
        ngx.log(ngx.ERR, "Failed to initialize MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local res, status = pcall(rate_limit, db, token)

    local ok, err = close_mysql(db)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close MySQL connection: ", err)
    end

    if not res then
        ngx.log(ngx.ERR, "Error during rate limit processing: ", status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    else
        ngx.exit(status)
    end
end

-- Run the main function
main()
