local mysql = require "resty.mysql"

local db, err = mysql:new()
if not db then
    ngx.log(ngx.ERR, "Failed to instantiate mysql: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

db:set_timeout(1000) -- 1 second timeout

local ok, err, errcode, sqlstate = db:connect{
    host = "mysql",
    port = 3306,
    database = "rate_limit_db",
    user = "root",
    password = "root",
    charset = "utf8mb4",
    max_packet_size = 1024 * 1024,
}

if not ok then
    ngx.log(ngx.ERR, "Failed to connect to MySQL: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Fetch the token from the URL parameter
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

local rate_limit = 5 -- 5 requests per minute
local window_size = 60 -- 60 second window

-- Get the current time
local current_time = ngx.now()

-- Fetch the current counter and expiry for the token
local select_query = string.format("SELECT count, expires_at FROM rate_limit_fixed_window WHERE token = %s", ngx.quote_sql_str(token))
local res, err, errcode, sqlstate = db:query(select_query)
if not res then
    ngx.log(ngx.ERR, "Failed to fetch rate limit data: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local count = 0
local expires_at = 0

-- If a record exists for the token
if #res > 0 then
    count = tonumber(res[1].count)
    expires_at = tonumber(res[1].expires_at)

    -- Check if the window has expired
    if current_time >= expires_at then
        -- Reset the count and expiry if the window has passed
        count = 0
        expires_at = current_time + window_size
    end
else
    -- If no record exists, set the expiry to the current time + window_size
    expires_at = current_time + window_size
end

-- Check if the request exceeds the rate limit
if count >= rate_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Increment the counter
count = count + 1

-- Insert or update the counter and expiry in the database
local insert_update_query = string.format([[
    INSERT INTO rate_limit_fixed_window (token, count, expires_at) 
    VALUES (%s, %d, %f) 
    ON DUPLICATE KEY UPDATE count = %d, expires_at = %f
]], ngx.quote_sql_str(token), count, expires_at, count, expires_at)

res, err, errcode, sqlstate = db:query(insert_update_query)
if not res then
    ngx.log(ngx.ERR, "Failed to update rate limit data: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Close the MySQL connection
local ok, err = db:set_keepalive(10000, 100)
if not ok then
    ngx.log(ngx.ERR, "Failed to set keepalive: ", err)
end
