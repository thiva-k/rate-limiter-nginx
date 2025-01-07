local mysql = require "resty.mysql"

local db_config = {
    host = "mysql",          -- Replace with your MySQL host
    port = 3306,
    database = "rate_limit_db",
    user = "root",           -- Replace with your MySQL username
    password = "root",       -- Replace with your MySQL password
    charset = "utf8mb4",
}

local rate_limit = 5
local window_size = 60

-- Initialize SQL connection
local function init_sql_connection()
    local db, err = mysql:new()
    if not db then
        ngx.log(ngx.ERR, "Failed to instantiate MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    db:set_timeout(1000)

    local ok, err, errcode, sqlstate = db:connect(db_config)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    return db
end

-- Close SQL connection
local function close_sql_connection(db)
    local ok, err = db:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.ERR, "Failed to return MySQL connection to the pool: ", err)
    end
end

-- Get token from query parameters
local function get_token()
    local token = ngx.var.arg_token
    if not token then
        ngx.say("Token is required")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    return token
end

-- Main rate limit logic
local function handle_rate_limit()
    local token = get_token()

    local db = init_sql_connection()

    local query = string.format(
        "CALL RateLimitCheck('%s', %d, %d, @status)",
        token,
        rate_limit,
        window_size
    )
    local res, err, errcode, sqlstate = db:query(query)
    if not res then
        ngx.log(ngx.ERR, "Query execution failed: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Consume any additional result sets
    while true do
        res, err, errcode, sqlstate = db:read_result()
        if not res then
            break
        end
    end

    -- Fetch the status
    local status_query = "SELECT @status AS status"
    local status_res, err, errcode, sqlstate = db:query(status_query)
    if not status_res then
        ngx.log(ngx.ERR, "Failed to fetch rate limit status: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local status = status_res[1].status
    if status == "TOO_MANY_REQUESTS" then
        ngx.status = ngx.HTTP_TOO_MANY_REQUESTS
        ngx.say("Too many requests")
    else
        ngx.say("Request allowed")
    end

    close_sql_connection(db)
end

handle_rate_limit()
