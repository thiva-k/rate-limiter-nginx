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
local rate_limit = 5           -- Max allowed requests
local window_size = 60         -- Time window in seconds

-- Initialize SQL Connection
local function init_sql_connection()
    local db, err = mysql:new()
    if not db then
        ngx.log(ngx.ERR, "Failed to instantiate MySQL object: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    db:set_timeout(1000) -- 1-second timeout

    local ok, err = db:connect(db_config)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    return db
end

-- Close SQL Connection
local function close_sql_connection(db)
    local ok, err = db:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set MySQL keepalive: ", err)
    end
end

-- Fetch Token from Request
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        ngx.say("Error: Token not provided")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    return token
end

-- Main Function to Handle Rate Limiting
local function handle_rate_limit()
    local token = get_token()
    local current_time = ngx.now()

    local db = init_sql_connection()

    -- Perform Rate Limiting Logic
    local select_query = string.format(
        "SELECT count, expires_at FROM rate_limit_fixed_window WHERE token = %s",
        ngx.quote_sql_str(token)
    )
    local res, err = db:query(select_query)
    if not res then
        ngx.log(ngx.ERR, "Failed to fetch rate limit data: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local count = 0
    local expires_at = 0

    if #res > 0 then
        -- Existing record found
        count = tonumber(res[1].count)
        expires_at = tonumber(res[1].expires_at)

        -- Check if the window has expired
        if current_time >= expires_at then
            count = 0
            expires_at = current_time + window_size
        end
    else
        -- No record exists, initialize expiry
        expires_at = current_time + window_size
    end

    -- Check if the request exceeds the rate limit
    if count >= rate_limit then
        ngx.status = ngx.HTTP_TOO_MANY_REQUESTS
        ngx.say("Rate limit exceeded")
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    -- Increment the counter and update the database
    count = count + 1
    local insert_update_query = string.format(
        [[
        INSERT INTO rate_limit_fixed_window (token, count, expires_at)
        VALUES (%s, %d, %f)
        ON DUPLICATE KEY UPDATE count = %d, expires_at = %f
        ]],
        ngx.quote_sql_str(token), count, expires_at, count, expires_at
    )

    res, err = db:query(insert_update_query)
    if not res then
        ngx.log(ngx.ERR, "Failed to update rate limit data: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    ngx.say("Request allowed for token: ", token)

    close_sql_connection(db)
end

-- Execute the main function
handle_rate_limit()
