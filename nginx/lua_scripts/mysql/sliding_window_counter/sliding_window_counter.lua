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

-- Delete outdated requests (requests outside the sliding window)
local delete_query = string.format("DELETE FROM rate_limit_sliding_window WHERE token = %s AND request_time < %f", 
    ngx.quote_sql_str(token), current_time - window_size)
local res, err, errcode, sqlstate = db:query(delete_query)
if not res then
    ngx.log(ngx.ERR, "Failed to clean up old rate limit data: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Count the number of requests made in the current window
local count_query = string.format("SELECT COUNT(*) as request_count FROM rate_limit_sliding_window WHERE token = %s", ngx.quote_sql_str(token))
local res, err, errcode, sqlstate = db:query(count_query)
if not res then
    ngx.log(ngx.ERR, "Failed to fetch rate limit count: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local request_count = tonumber(res[1].request_count)

-- Check if the request exceeds the rate limit
if request_count >= rate_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Log the current request by inserting the current timestamp into the database
local insert_query = string.format("INSERT INTO rate_limit_sliding_window (token, request_time) VALUES (%s, %f)", 
    ngx.quote_sql_str(token), current_time)
local res, err, errcode, sqlstate = db:query(insert_query)
if not res then
    ngx.log(ngx.ERR, "Failed to log request to MySQL: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Close the MySQL connection
local ok, err = db:set_keepalive(10000, 100)
if not ok then
    ngx.log(ngx.ERR, "Failed to set keepalive: ", err)
end

ngx.say("Request allowed")
