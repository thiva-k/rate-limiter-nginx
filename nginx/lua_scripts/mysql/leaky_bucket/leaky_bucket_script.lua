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

-- Leaky bucket parameters
local bucket_capacity = 10 -- Maximum tokens in the bucket
local leak_rate = 1 -- Tokens leaked per second
local requested_tokens = 1 -- Number of tokens required per request

-- Helper function to initialize MySQL connection
local function init_mysql()
    local db, err = mysql:new()
    if not db then
        ngx.log(ngx.ERR, "Failed to create MySQL object: ", err or "unknown")
        return nil, "Failed to create MySQL object: " .. (err or "unknown")
    end

    db:set_timeout(1000) -- 1-second timeout

    local ok, err, errno, sqlstate = db:connect(mysql_config)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err or "unknown")
        return nil, "Failed to connect to MySQL: " .. (err or "unknown")
    end
    return db
end

-- Helper function to close MySQL connection
local function close_mysql(db)
    -- Clear pending results to reset the connection state
    repeat
        local res, err = db:read_result()
        if not res then
            break
        end
    until false

    local ok, err = db:set_keepalive(10000, 50) -- 10 seconds timeout, max 50 idle connections
    if not ok then
        ngx.log(ngx.ERR, "Failed to set MySQL keepalive: ", err or "unknown")
        return nil, "Failed to set MySQL keepalive: " .. (err or "unknown")
    end
    return true
end

-- Helper function to get URL token
local function get_user_url_token()
    local token = ngx.var.arg_token
    ngx.log(ngx.DEBUG, "Received token: ", token or "nil")
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Main rate-limiting logic using the leaky bucket stored procedure
local function rate_limit(db, token)
    ngx.log(ngx.DEBUG, "Invoking leaky bucket rate limiter for token: ", token)

    -- Prepare the stored procedure call
    local call_query = string.format(
        "CALL LeakyBucketRateLimit('%s', %d, %d, %d, @p_status);",
        token, bucket_capacity, leak_rate, requested_tokens
    )
    ngx.log(ngx.DEBUG, "Executing query: ", call_query)

    -- Execute the stored procedure
    local res, err, errno, sqlstate = db:query(call_query)
    if not res then
        ngx.log(ngx.ERR, "Failed to execute stored procedure: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Clear any remaining results to reset the connection state
    repeat
        local res, err = db:read_result()
        if not res then
            break
        end
    until false

    -- Fetch the output parameter value
    local select_query = "SELECT @p_status AS status;"
    ngx.log(ngx.DEBUG, "Executing query to fetch output parameter: ", select_query)

    res, err, errno, sqlstate = db:query(select_query)
    if not res then
        ngx.log(ngx.ERR, "Failed to fetch output parameter: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Validate the result
    if not res[1] or not res[1].status then
        ngx.log(ngx.ERR, "Output parameter @p_status not found")
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    -- Return the status from the stored procedure
    local status = res[1].status
    if status == "ALLOWED" then
        ngx.log(ngx.DEBUG, "Request allowed for token: ", token)
        ngx.say("Request allowed")
        return ngx.HTTP_OK
    else
        ngx.log(ngx.WARN, "Rate limit exceeded for token: ", token)
        ngx.say("Rate limit exceeded")
        return ngx.HTTP_TOO_MANY_REQUESTS
    end
end



-- Main function to initialize MySQL and handle rate limiting
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
        ngx.log(ngx.ERR, "Error during rate limiting: ", status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    else
        ngx.exit(status)
    end
end

-- Run the main function
main()
