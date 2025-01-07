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
        ngx.log(ngx.ERR, "DEBUG: Failed to create mysql object: ", err or "unknown")
        return nil, "Failed to create mysql object: " .. (err or "unknown")
    end

    db:set_timeout(1000) -- 1 second timeout

    local ok, err, errno, sqlstate = db:connect(mysql_config)
    if not ok then
        ngx.log(ngx.ERR, "DEBUG: Failed to connect to MySQL: ", err or "unknown")
        return nil, "Failed to connect to MySQL: " .. (err or "unknown")
    end
    return db
end

-- Helper function to close MySQL connection
local function close_mysql(db)
    local ok, err = db:set_keepalive(10000, 50) -- 10 seconds timeout, max 50 idle connections
    if not ok then
        ngx.log(ngx.ERR, "DEBUG: Failed to set MySQL keepalive: ", err or "unknown")
        return nil, "Failed to set MySQL keepalive: " .. (err or "unknown")
    end
    return true
end

-- Helper function to get URL token
local function get_user_url_token()
    local token = ngx.var.arg_token
    ngx.log(ngx.DEBUG, "DEBUG: Received token: ", token or "nil")
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Main rate limiting logic
local function rate_limit(db, token)
    -- MySQL query to fetch the current token count and last access time
    local query = string.format(
        "SELECT tokens, last_access FROM rate_limit WHERE token = '%s' FOR UPDATE",
        token
    )
    ngx.log(ngx.DEBUG, "DEBUG: Executing query: ", query)

    local res, err, errno, sqlstate = db:query(query)
    if not res then
        ngx.log(ngx.ERR, "DEBUG: Failed to query MySQL: ", err)
        return ngx.HTTP_INTERNAL_SERVER_ERROR
    end

    local now = ngx.now() * 1000 -- Current timestamp in milliseconds
    local bucket_level = 0
    local last_access = now

    if #res > 0 then
        bucket_level = tonumber(res[1].tokens) or 0
        last_access = tonumber(res[1].last_access) or now
    else
        ngx.log(ngx.DEBUG, "DEBUG: No record found for token, inserting default values")
        local insert_query = string.format(
            "INSERT INTO rate_limit (token, tokens, last_access) VALUES ('%s', 0, %d)",
            token,
            now
        )
        local ok, err, errno, sqlstate = db:query(insert_query)
        if not ok then
            ngx.log(ngx.ERR, "DEBUG: Failed to insert into MySQL: ", err)
            return ngx.HTTP_INTERNAL_SERVER_ERROR
        end
    end

    ngx.log(ngx.DEBUG, "DEBUG: Current bucket level: ", bucket_level, ", Last access: ", last_access)

    local elapsed = math.max(0, now - last_access)
    local leaked_tokens = math.floor(elapsed * leak_rate / 1000)
    bucket_level = math.max(0, bucket_level - leaked_tokens)

    ngx.log(ngx.DEBUG, "DEBUG: Elapsed time: ", elapsed, "ms, Leaked tokens: ", leaked_tokens)
    ngx.log(ngx.DEBUG, "DEBUG: Bucket level after leaking: ", bucket_level)

    if bucket_level + requested_tokens <= bucket_capacity then
        bucket_level = bucket_level + requested_tokens

        local update_query = string.format(
            "UPDATE rate_limit SET tokens = %d, last_access = %d WHERE token = '%s'",
            bucket_level,
            now,
            token
        )
        ngx.log(ngx.DEBUG, "DEBUG: Executing update query: ", update_query)

        local ok, err, errno, sqlstate = db:query(update_query)
        if not ok then
            ngx.log(ngx.ERR, "DEBUG: Failed to update MySQL: ", err)
            return ngx.HTTP_INTERNAL_SERVER_ERROR
        end

        ngx.log(ngx.DEBUG, "DEBUG: Rate limiting succeeded, bucket level: ", bucket_level)
        ngx.say("Request allowed")
        return ngx.HTTP_OK
    else
        ngx.log(ngx.WARN, "DEBUG: Rate limit exceeded for token: ", token)
        ngx.say("Rate limit exceeded")
        return ngx.HTTP_TOO_MANY_REQUESTS
    end
end

-- Main function to initialize MySQL and handle rate limiting
local function main()
    local token, err = get_user_url_token()
    if not token then
        ngx.log(ngx.ERR, "DEBUG: Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local db, err = init_mysql()
    if not db then
        ngx.log(ngx.ERR, "DEBUG: Failed to initialize MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local res, status = pcall(rate_limit, db, token)

    local ok, err = close_mysql(db)
    if not ok then
        ngx.log(ngx.ERR, "DEBUG: Failed to close MySQL connection: ", err)
    end

    if not res then
        ngx.log(ngx.ERR, "DEBUG: Error during rate limiting: ", status)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    else
        ngx.exit(status)
    end
end

-- Run the main function
main()
