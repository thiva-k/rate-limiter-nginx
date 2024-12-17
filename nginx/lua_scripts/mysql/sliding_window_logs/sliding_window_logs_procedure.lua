local mysql = require "resty.mysql"

local db, err = mysql:new()
if not db then
    ngx.log(ngx.ERR, "Failed to instantiate mysql: ", err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

db:set_timeout(1000)

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

-- Fetch the token
local token = ngx.var.arg_token
if not token then
    ngx.log(ngx.ERR, "Token not provided")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

-- Sliding window parameters
local rate_limit = 5 -- 5 requests
local window_size = 60 -- 1 minute

-- Call the stored procedure and set user-defined variable
local call_res, call_err, call_errcode, call_sqlstate = db:query(
    string.format("CALL rate_limit_db.RateLimitCheck(%s, %d, %d, @is_allowed)", 
    ngx.quote_sql_str(token), 
    window_size, 
    rate_limit)
)

if not call_res then
    ngx.log(ngx.ERR, "Failed to execute procedure: ", call_err, 
            " Errcode: ", call_errcode, 
            " Sqlstate: ", call_sqlstate)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Retrieve the output variable
local select_res, select_err = db:query("SELECT @is_allowed AS is_allowed")
if not select_res then
    ngx.log(ngx.ERR, "Failed to retrieve procedure result: ", select_err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Check the result
local is_allowed = tonumber(select_res[1]["is_allowed"])
if is_allowed == 0 then
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

-- Close the connection
local ok, err = db:set_keepalive(10000, 100)
if not ok then
    ngx.log(ngx.ERR, "Failed to set keepalive: ", err)
end