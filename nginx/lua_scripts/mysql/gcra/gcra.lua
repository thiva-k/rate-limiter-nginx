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

local period = 60 -- Time window of 1 minute
local rate = 5 -- 5 requests per minute
local burst = 2 -- Allow burst of up to 2 requests
local emission_interval = period / rate
local delay_tolerance = emission_interval * burst

-- Get the current time (in seconds)
local current_time = ngx.now()

-- Fetch the stored TAT (Theoretical Arrival Time) from MySQL
local select_query = string.format("SELECT tat FROM rate_limit_gcra WHERE token = %s", ngx.quote_sql_str(token))
local res, err, errcode, sqlstate = db:query(select_query)
if not res then
    ngx.log(ngx.ERR, "Failed to fetch TAT from MySQL: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local tat = -1
if #res > 0 then
    tat = tonumber(res[1].tat)
end

-- If it's the first request, initialize the TAT to the current time
if tat == -1 then
    tat = current_time
end

-- Compute the time when the request is allowed
local allow_at = tat - delay_tolerance

-- Check if the current request is allowed
if current_time >= allow_at then
    -- Request is allowed, so update the TAT to the next allowed time
    tat = math.max(current_time, tat) + emission_interval

    -- Update the TAT in MySQL
    local update_query = string.format([[
        INSERT INTO rate_limit_gcra (token, tat)
        VALUES (%s, %f)
        ON DUPLICATE KEY UPDATE tat = %f
    ]], ngx.quote_sql_str(token), tat, tat)
    local res, err, errcode, sqlstate = db:query(update_query)
    if not res then
        ngx.log(ngx.ERR, "Failed to update TAT in MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    ngx.say("Request allowed")
else
    -- Request is not allowed
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Close the MySQL connection
local ok, err = db:set_keepalive(10000, 100)
if not ok then
    ngx.log(ngx.ERR, "Failed to set keepalive: ", err)
end
