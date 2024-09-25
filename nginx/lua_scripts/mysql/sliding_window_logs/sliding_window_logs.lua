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

-- Hardcoded rate limit and window size
local rate_limit = 5 -- 5 requests per minute
local window_size = 60 -- 1 minute window

-- Get the current timestamp
local current_time = ngx.now()

-- Remove old entries (manual interpolation of values, no extra quotes)
local remove_time = current_time - window_size
local remove_query = string.format(
    "DELETE FROM rate_limit_entries WHERE token = %s AND timestamp < %f", 
    ngx.quote_sql_str(token), 
    remove_time
)

local res, err, errcode, sqlstate = db:query(remove_query)
if not res then
    ngx.log(ngx.ERR, "Failed to remove old entries: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Count current entries (manual interpolation of values, no extra quotes)
local count_query = string.format(
    "SELECT COUNT(*) as count FROM rate_limit_entries WHERE token = %s AND timestamp >= %f", 
    ngx.quote_sql_str(token), 
    remove_time
)

res, err, errcode, sqlstate = db:query(count_query)
if not res then
    ngx.log(ngx.ERR, "Failed to count current entries: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local count = tonumber(res[1].count)

-- Check if the number of requests exceeds the rate limit
if count >= rate_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Add the new entry (manual interpolation of values, no extra quotes)
local insert_query = string.format(
    "INSERT INTO rate_limit_entries (token, timestamp) VALUES (%s, %f)", 
    ngx.quote_sql_str(token), 
    current_time
)

res, err, errcode, sqlstate = db:query(insert_query)
if not res then
    ngx.log(ngx.ERR, "Failed to add new entry: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Close the connection
local ok, err = db:set_keepalive(10000, 100)
if not ok then
    ngx.log(ngx.ERR, "Failed to set keepalive: ", err)
end
