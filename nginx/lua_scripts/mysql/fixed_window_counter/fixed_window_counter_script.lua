local mysql = require "resty.mysql"

local db_config = {
    host = "mysql",
    port = 3306,
    database = "rate_limit_db",
    user = "root",
    password = "root",
    charset = "utf8mb4",
    max_packet_size = 1024 * 1024,
}

local rate_limit = 5
local window_size = 60

local procedure_script = [[
CREATE PROCEDURE RateLimitCheck(
    IN p_token VARCHAR(255),
    IN p_rate_limit INT,
    IN p_window_size INT,
    OUT p_status VARCHAR(20)
)
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_expires_at DOUBLE DEFAULT 0;
    DECLARE v_current_time DOUBLE;

    SET v_current_time = UNIX_TIMESTAMP(NOW());

    SELECT count, expires_at INTO v_count, v_expires_at
    FROM rate_limit_fixed_window
    WHERE token = p_token;

    -- Debug: Insert intermediate state into a debug table
    INSERT INTO debug_log (message, timestamp)
    VALUES (CONCAT('Current time: ', v_current_time, ', Count: ', IFNULL(v_count, 0), ', Expires at: ', IFNULL(v_expires_at, 0)), NOW());

    IF v_count IS NULL THEN
        INSERT INTO rate_limit_fixed_window (token, count, expires_at)
        VALUES (p_token, 1, v_current_time + p_window_size);
        SET p_status = 'ALLOWED';
    ELSE
        IF v_current_time >= v_expires_at THEN
            UPDATE rate_limit_fixed_window
            SET count = 1, expires_at = v_current_time + p_window_size
            WHERE token = p_token;
            SET p_status = 'ALLOWED';
        ELSE
            IF v_count + 1 > p_rate_limit THEN
                SET p_status = 'TOO_MANY_REQUESTS';
            ELSE
                UPDATE rate_limit_fixed_window
                SET count = count + 1
                WHERE token = p_token;
                SET p_status = 'ALLOWED';
            END IF;
        END IF;
    END IF;

    -- Debug: Log the final status
    INSERT INTO debug_log (message, timestamp)
    VALUES (CONCAT('Final status: ', p_status), NOW());
END;
]]

local function handle_rate_limit()
    local token = ngx.var.arg_token
    if not token then
        ngx.log(ngx.ERR, "Token not provided")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

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

    -- Check if the procedure already exists
    local check_query = [[
        SELECT COUNT(*) AS count
        FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA = 'rate_limit_db' AND ROUTINE_NAME = 'RateLimitCheck' AND ROUTINE_TYPE = 'PROCEDURE';
    ]]
    local res, err, errcode, sqlstate = db:query(check_query)
    if not res then
        ngx.log(ngx.ERR, "Failed to check for stored procedure: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if res[1] and tonumber(res[1].count) == 0 then
        ngx.log(ngx.INFO, "Creating stored procedure RateLimitCheck.")
        res, err, errcode, sqlstate = db:query(procedure_script)
        if not res then
            ngx.log(ngx.ERR, "Failed to create stored procedure: ", err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    else
        ngx.log(ngx.INFO, "Stored procedure RateLimitCheck already exists.")
    end

    -- Execute the stored procedure
    local query = string.format(
        "CALL RateLimitCheck('%s', %d, %d, @status)",
        token,
        rate_limit,
        window_size
    )
    ngx.log(ngx.INFO, "Executing query: ", query)
    res, err, errcode, sqlstate = db:query(query)
    if not res then
        ngx.log(ngx.ERR, "Failed to execute stored procedure: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Consume all result sets from the stored procedure
    while true do
        res, err, errcode, sqlstate = db:read_result()
        if not res then
            if err == "again" then
                -- More results to process, continue looping
                ngx.log(ngx.INFO, "Reading next result set.")
            else
                -- No more result sets to read, break the loop
                break
            end
        end
    end

    -- Fetch the status
    local status_query = "SELECT @status AS status"
    ngx.log(ngx.INFO, "Executing query: ", status_query)
    local status_res, err, errcode, sqlstate = db:query(status_query)
    if not status_res then
        ngx.log(ngx.ERR, "Failed to fetch rate limit status: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local status = status_res[1].status
    ngx.log(ngx.INFO, "Rate limit status: ", status)

    if status == "TOO_MANY_REQUESTS" then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    local ok, err = db:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set keepalive: ", err)
    end

    ngx.say("Request allowed")
end

handle_rate_limit()
