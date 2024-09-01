local mysql = require "resty.mysql"

local db, err = mysql:new()
if not db then
    ngx.log(ngx.ERR, "Failed to instantiate MySQL: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

db:set_timeout(1000)  -- 1 second timeout

local ok, err, errcode, sqlstate = db:connect{
    host = "127.0.0.1",
    port = 3306,
    database = "rate_limiter",
    user = "user",
    password = "password"
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
local rate_limit = 100 -- 100 requests per minute
local window_size = 60 -- 1 minute window

local current_time = ngx.now()

-- Retrieve the current timestamps for the token
local res, err, errcode, sqlstate =
    db:query("SELECT request_timestamps FROM rate_limits WHERE token = " .. ngx.quote_sql_str(token))

if not res then
    ngx.log(ngx.ERR, "Failed to query MySQL: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local timestamps = {}
if #res > 0 then
    timestamps = cjson.decode(res[1].request_timestamps)
end

-- Remove timestamps outside the current window
local new_timestamps = {}
for _, timestamp in ipairs(timestamps) do
    if current_time - tonumber(timestamp) < window_size then
        table.insert(new_timestamps, timestamp)
    end
end

-- Add the current request timestamp
table.insert(new_timestamps, current_time)

-- Check if the number of requests exceeds the rate limit
if #new_timestamps > rate_limit then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Update the timestamps in the database
local new_timestamps_json = cjson.encode(new_timestamps)
local res, err, errcode, sqlstate = db:query(
    "INSERT INTO rate_limits (token, request_timestamps) VALUES (" .. ngx.quote_sql_str(token) .. ", " .. ngx.quote_sql_str(new_timestamps_json) ..
    ") ON DUPLICATE KEY UPDATE request_timestamps = VALUES(request_timestamps)"
)

if not res then
    ngx.log(ngx.ERR, "Failed to update MySQL: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

ngx.exit(ngx.HTTP_OK)