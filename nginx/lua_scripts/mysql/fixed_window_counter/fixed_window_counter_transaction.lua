local mysql = require "resty.mysql"

-- MySQL Database Configuration
local db_config = {
    host = "mysql",
    port = 3306,
    database = "rate_limit_db",
    user = "root",
    password = "root",
    charset = "utf8mb4",
    max_packet_size = 1024 * 1024,
}

-- Rate limit parameters
local rate_limit = 5            -- Max allowed requests
local window_size = 60          -- Time window in seconds
local current_time = ngx.now()  -- Current time as UNIX timestamp


-- Function to Handle Rate Limiting Logic
local function handle_rate_limit()
    -- Fetch the token from the request
    local token = ngx.var.arg_token
    if not token then
        local error_msg = "Error: Token not provided"
        ngx.log(ngx.ERR, error_msg)
        ngx.say(error_msg)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Create MySQL connection
    local db, err = mysql:new()
    if not db then
        local error_msg = "Error: Failed to instantiate MySQL object: " .. (err or "Unknown error")
        ngx.log(ngx.ERR, error_msg)
        ngx.say(error_msg)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    db:set_timeout(1000) -- 1-second timeout

    local ok, err = db:connect(db_config)
    if not ok then
        local error_msg = "Error: Failed to connect to MySQL. Details: " .. (err or "Unknown error")
        ngx.log(ngx.ERR, error_msg, ", Parameters: host=", db_config.host, ", database=", db_config.database)
        ngx.say(error_msg)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Start a transaction
    local res, err = db:query("START TRANSACTION;")
    if not res then
        local error_msg = "Error: Failed to start transaction. Details: " .. (err or "Unknown error")
        ngx.log(ngx.ERR, error_msg)
        ngx.say(error_msg)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Fetch existing count and expiry from the database
    local select_query = string.format(
        "SELECT count, expires_at FROM rate_limit_fixed_window WHERE token = %s",
        ngx.quote_sql_str(token)
    )
    res, err = db:query(select_query)
    if not res then
        local error_msg = "Error: Failed to fetch rate limit data for token: " .. token .. ". Details: " .. (err or "Unknown error")
        ngx.log(ngx.ERR, error_msg, ", Query: ", select_query)
        db:query("ROLLBACK;")
        ngx.say(error_msg)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local count = 0
    local expires_at = 0

    -- Step 1: Handle no existing record or window expiration
    if #res == 0 or current_time >= tonumber(res[1].expires_at) then
        -- Reset the window: count = 1 and set new expiry
        local reset_query = string.format(
            "REPLACE INTO rate_limit_fixed_window (token, count, expires_at) VALUES (%s, 1, %f)",
            ngx.quote_sql_str(token), current_time + window_size
        )
        res, err = db:query(reset_query)
        if not res then
            local error_msg = "Error: Failed to reset rate limit for token: " .. token .. ". Details: " .. (err or "Unknown error")
            ngx.log(ngx.ERR, error_msg, ", Query: ", reset_query)
            db:query("ROLLBACK;")
            ngx.say(error_msg)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    else
        -- Step 2: Increment the count if within the window
        count = tonumber(res[1].count)
        expires_at = tonumber(res[1].expires_at)

        if count + 1 > rate_limit then
            local error_msg = string.format("Rate limit exceeded for token: %s, Current count: %d, Rate limit: %d", token, count, rate_limit)
            ngx.log(ngx.ERR, error_msg)
            db:query("ROLLBACK;")
            ngx.status = ngx.HTTP_TOO_MANY_REQUESTS
            ngx.say(error_msg)
            ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
        end

        -- Increment the count
        local update_query = string.format(
            "UPDATE rate_limit_fixed_window SET count = count + 1 WHERE token = %s",
            ngx.quote_sql_str(token)
        )
        res, err = db:query(update_query)
        if not res then
            local error_msg = "Error: Failed to increment count for token: " .. token .. ". Details: " .. (err or "Unknown error")
            ngx.log(ngx.ERR, error_msg, ", Query: ", update_query)
            db:query("ROLLBACK;")
            ngx.say(error_msg)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    end

    -- Commit the transaction
    res, err = db:query("COMMIT;")
    if not res then
        local error_msg = "Error: Failed to commit transaction for token: " .. token .. ". Details: " .. (err or "Unknown error")
        ngx.log(ngx.ERR, error_msg)
        ngx.say(error_msg)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Success response
    ngx.say("Request allowed for token: ", token)

    -- Return MySQL connection to the pool
    local ok, err = db:set_keepalive(10000, 100)
    if not ok then
        local error_msg = "Error: Failed to set MySQL keepalive for token: " .. token .. ". Details: " .. (err or "Unknown error")
        ngx.log(ngx.ERR, error_msg)
        ngx.say(error_msg)
    end
end

-- Call the handle_rate_limit function
handle_rate_limit()
