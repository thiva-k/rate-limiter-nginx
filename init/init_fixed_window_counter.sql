-- Initialize the database
CREATE DATABASE IF NOT EXISTS rate_limit_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
-- Switch to the database
USE rate_limit_db;

-- Create the rate-limiting table
CREATE TABLE IF NOT EXISTS rate_limit_fixed_window (
    token VARCHAR(255) PRIMARY KEY,  -- The token used for rate limiting (e.g., user ID or API key)
    count INT DEFAULT 0,             -- The current request count for the token
    expires_at DOUBLE DEFAULT 0      -- The expiration timestamp of the current rate limit window
);

-- Optional: Create a debug log table for logging
CREATE TABLE IF NOT EXISTS debug_log (
    id INT AUTO_INCREMENT PRIMARY KEY,
    message TEXT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Drop the procedure if it already exists
DROP PROCEDURE IF EXISTS RateLimitCheck;

-- Change the delimiter for procedure creation
DELIMITER //

-- Create the stored procedure
CREATE PROCEDURE RateLimitCheck(
    IN p_token VARCHAR(255),         -- Input: The token
    IN p_rate_limit INT,             -- Input: Max requests per window
    IN p_window_size INT,            -- Input: Time window in seconds
    OUT p_status VARCHAR(20)         -- Output: Result status (ALLOWED/TOO_MANY_REQUESTS)
)
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_expires_at DOUBLE DEFAULT 0;
    DECLARE v_current_time DOUBLE;

    SET v_current_time = UNIX_TIMESTAMP(NOW());

    -- Fetch the token details
    SELECT IFNULL(count, 0), IFNULL(expires_at, 0) INTO v_count, v_expires_at
    FROM rate_limit_fixed_window
    WHERE token = p_token;

    IF v_count = 0 AND v_expires_at = 0 THEN
        -- Insert a new record
        INSERT INTO rate_limit_fixed_window (token, count, expires_at)
        VALUES (p_token, 1, v_current_time + p_window_size);
        SET p_status = 'ALLOWED';
    ELSEIF v_current_time >= v_expires_at THEN
        -- Reset the count if the window expired
        UPDATE rate_limit_fixed_window
        SET count = 1, expires_at = v_current_time + p_window_size
        WHERE token = p_token;
        SET p_status = 'ALLOWED';
    ELSE
        -- Within the same window
        IF v_count + 1 > p_rate_limit THEN
            SET p_status = 'TOO_MANY_REQUESTS';
        ELSE
            -- Increment the request count
            UPDATE rate_limit_fixed_window
            SET count = count + 1
            WHERE token = p_token;
            SET p_status = 'ALLOWED';
        END IF;
    END IF;
END;
//

-- Reset the delimiter back to `;`
DELIMITER ;

-- Optional test query to verify the procedure
-- CALL RateLimitCheck('test_token', 5, 60, @status);
-- SELECT @status;
