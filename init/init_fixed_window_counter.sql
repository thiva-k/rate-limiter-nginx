-- Create the rate limit table
CREATE DATABASE IF NOT EXISTS rate_limit_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
USE rate_limit_db;

-- Table to track rate limits per token
CREATE TABLE IF NOT EXISTS rate_limit_log (
    token VARCHAR(255) NOT NULL,
    window_start BIGINT UNSIGNED NOT NULL,
    request_count INT UNSIGNED NOT NULL,
    PRIMARY KEY (token, window_start)
);

DELIMITER //

CREATE PROCEDURE check_rate_limit(
    IN p_input_token VARCHAR(255),
    IN p_window_size INT,
    IN p_rate_limit INT,
    OUT o_is_limited INT
)
BEGIN
    DECLARE v_current_time BIGINT UNSIGNED;
    DECLARE v_window_start BIGINT UNSIGNED;
    DECLARE v_current_count INT UNSIGNED DEFAULT 0;

    SET v_current_time = UNIX_TIMESTAMP();

    -- Calculate window start time
    SET v_window_start = FLOOR(v_current_time / p_window_size) * p_window_size;

    START TRANSACTION;

    -- Check if an entry exists for the current window
    SELECT IFNULL(request_count, 0) 
    INTO v_current_count
    FROM rate_limit_log
    WHERE token = p_input_token AND window_start = v_window_start
    FOR UPDATE;

    IF v_current_count = 0 THEN
        INSERT INTO rate_limit_log (token, window_start, request_count)
        VALUES (p_input_token, v_window_start, 1);
        SET o_is_limited = 0;
    ELSE
        IF v_current_count + 1 > p_rate_limit THEN
            SET o_is_limited = 1;
        ELSE
            UPDATE rate_limit_log
            SET request_count = request_count + 1
            WHERE token = p_input_token AND window_start = v_window_start;
            SET o_is_limited = 0;
        END IF;
    END IF;

    COMMIT;
END //

DELIMITER ;