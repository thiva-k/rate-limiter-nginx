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
    ngx.log(ngx.DEBUG, "Initializing MySQL connection...")
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

    ngx.log(ngx.DEBUG, "MySQL connection established successfully.")
    return db
end

-- Helper function to close MySQL connection
local function close_mysql(db)
    ngx.log(ngx.DEBUG, "Closing MySQL connection...")
    local ok, err = db:set_keepalive(10000, 100) -- 10 seconds, 100 connections
    if not ok then
        ngx.log(ngx.ERR, "Failed to set MySQL keepalive: ", err)
        return nil, err
    end

    ngx.log(ngx.DEBUG, "MySQL connection closed successfully.")
    return true
end

-- Helper function to get URL token
local function get_user_url_token()
    ngx.log(ngx.DEBUG, "Fetching token from request arguments...")
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided in request.")
        return nil, "Token not provided"
    end

    ngx.log(ngx.DEBUG, "Token fetched: ", token)
    return token
end

-- Main rate limiting logic
local function rate_limit(db, token)
    ngx.log(ngx.DEBUG, "Starting rate limit logic for token: ", token)
    local now = ngx.now() * 1000 -- Current timestamp in milliseconds

    -- Fetch current tokens and last access time from the database
    local query = string.format([[
        SELECT tokens, last_access
        FROM rate_limit
        WHERE token = %s
    ]], ngx.quote_sql_str(token))

    ngx.log(ngx.DEBUG, "Executing query to fetch token state: ", query)
    local res, err, errcode, sqlstate = db:query(query)
    if not res then
        ngx.log(ngx.ERR, "Failed to execute query: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    ngx.log(ngx.DEBUG, "Query result: ", require("cjson").encode(res))

    local last_tokens = bucket_capacity
    local last_access = now

    if #res > 0 then
        last_tokens = tonumber(res[1].tokens) or bucket_capacity
        last_access = tonumber(res[1].last_access) or now
        ngx.log(ngx.DEBUG, "Existing token state found. Tokens: ", last_tokens, ", Last Access: ", last_access)
    else
        ngx.log(ngx.DEBUG, "No existing token state found. Initializing new state.")
        -- If no record exists, insert a new one
        local insert_query = string.format([[
            INSERT INTO rate_limit (token, tokens, last_access)
            VALUES (%s, %f, %d)
        ]], ngx.quote_sql_str(token), bucket_capacity, now)

        local ok, err, errcode, sqlstate = db:query(insert_query)
        if not ok then
            ngx.log(ngx.ERR, "Failed to insert token record: ", err)
            return ngx.HTTP_INTERNAL_SERVER_ERROR
        end
    end

    -- Calculate the number of tokens to be added due to the elapsed time
    local elapsed = math.max(0, now - last_access)
    local add_tokens = elapsed * refill_rate / 1000
    local new_tokens = math.min(bucket_capacity, last_tokens + add_tokens)

    ngx.log(ngx.DEBUG, "Elapsed time: ", elapsed, " ms, Tokens to add: ", add_tokens, ", New tokens: ", new_tokens)

    -- Check if there are enough tokens for the request
    if new_tokens >= requested_tokens then
        new_tokens = new_tokens - requested_tokens
        ngx.log(ngx.DEBUG, "Request allowed. Deducting tokens. New token count: ", new_tokens)

        -- Update the database with new token count and access time
        local update_query = string.format([[
            UPDATE rate_limit
            SET tokens = %f, last_access = %d
            WHERE token = %s
        ]], new_tokens, now, ngx.quote_sql_str(token))

        local ok, err, errcode, sqlstate = db:query(update_query)
        if not ok then
            ngx.log(ngx.ERR, "Failed to update token record: ", err)
            return ngx.HTTP_INTERNAL_SERVER_ERROR
        end

        ngx.say("Request allowed")
        return ngx.HTTP_OK
    else
        -- Not enough tokens, rate limit the request
        ngx.log(ngx.DEBUG, "Request denied. Not enough tokens. Current tokens: ", new_tokens)
        return ngx.HTTP_TOO_MANY_REQUESTS
    end
end

-- Main function to initialize MySQL and handle rate limiting
local function main()
    ngx.log(ngx.DEBUG, "Starting main function...")
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
