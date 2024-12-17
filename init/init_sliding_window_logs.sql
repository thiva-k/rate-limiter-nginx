-- Change authentication method for root user
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

-- Create the database if it doesn't exist
CREATE DATABASE IF NOT EXISTS rate_limit_db;

-- Use the rate limit database
USE rate_limit_db;

-- Create the table for rate limiting
CREATE TABLE IF NOT EXISTS rate_limit_entries (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    token VARCHAR(255) NOT NULL,
    timestamp DOUBLE NOT NULL,
    INDEX idx_token_timestamp (token, timestamp)
) ENGINE=InnoDB;

-- Drop the procedure if it already exists
DROP PROCEDURE IF EXISTS rate_limit_db.RateLimitCheck;

DELIMITER //

CREATE PROCEDURE rate_limit_db.RateLimitCheck(
    IN p_token VARCHAR(255),
    IN p_window_size INT,
    IN p_rate_limit INT,
    OUT p_is_allowed BOOLEAN
)
BEGIN
    DECLARE v_current_time DOUBLE DEFAULT UNIX_TIMESTAMP();
    DECLARE v_valid_start_time DOUBLE DEFAULT v_current_time - p_window_size;
    DECLARE v_request_count INT;

    -- Delete outdated entries specific to the user token
    DELETE FROM rate_limit_entries
    WHERE token = p_token AND timestamp < v_valid_start_time;

    -- Count requests within the current window
    SELECT COUNT(*) INTO v_request_count
    FROM rate_limit_entries
    WHERE token = p_token AND timestamp >= v_valid_start_time;

    -- Check if the request is within the rate limit
    IF v_request_count < p_rate_limit THEN
        -- Insert the current request and allow
        INSERT INTO rate_limit_entries (token, timestamp) 
        VALUES (p_token, v_current_time);
        SET p_is_allowed = TRUE;
    ELSE
        -- Reject the request
        SET p_is_allowed = FALSE;
    END IF;
END //

DELIMITER ;