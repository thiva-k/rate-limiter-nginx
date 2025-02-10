CREATE DATABASE IF NOT EXISTS rate_limit_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
USE rate_limit_db;

-- Table to store request timestamps per token
CREATE TABLE IF NOT EXISTS sliding_window_log (
    token VARCHAR(255) NOT NULL,
    request_time TIMESTAMP(3) NOT NULL,    -- Using TIMESTAMP with 3 decimal places for millisecond precision
    PRIMARY KEY (token, request_time)
);

DELIMITER //
CREATE PROCEDURE check_sliding_window_limit(
    IN p_input_token VARCHAR(255),
    IN p_window_size INT,
    IN p_rate_limit INT
)
BEGIN
    DECLARE v_current_time TIMESTAMP(3);
    DECLARE v_request_count INT;
    
    -- Get current timestamp with millisecond precision
    SET v_current_time = CURRENT_TIMESTAMP(3);
    
    START TRANSACTION;
    
    -- Remove outdated requests outside the sliding window
    DELETE FROM sliding_window_log
    WHERE token = p_input_token 
    AND request_time < (v_current_time - INTERVAL p_window_size SECOND);
    
    -- Count the remaining requests within the current window
    SELECT COUNT(*)
    INTO v_request_count
    FROM sliding_window_log
    WHERE token = p_input_token;
    
    IF v_request_count < p_rate_limit THEN
        -- Log the current request
        INSERT INTO sliding_window_log (token, request_time)
        VALUES (p_input_token, v_current_time);
        SELECT 0 AS is_limited;
    ELSE
        SELECT 1 AS is_limited;
    END IF;
    
    COMMIT;
END //
DELIMITER ;