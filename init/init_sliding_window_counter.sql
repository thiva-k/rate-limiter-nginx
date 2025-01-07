-- Set authentication to native password
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

-- Use the rate_limit_db
USE rate_limit_db;
CREATE TABLE rate_limit_requests (
    token VARCHAR(255) NOT NULL,
    subwindow BIGINT NOT NULL,
    request_count INT DEFAULT 0,
    PRIMARY KEY (token, subwindow)
);

CREATE TABLE debug_log (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    log_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    log_message TEXT
);


DELIMITER //

CREATE PROCEDURE rate_limit_check(
    IN p_token VARCHAR(255),
    IN p_current_subwindow BIGINT,
    IN p_window_size INT,
    IN p_sub_window_count INT,
    IN p_request_limit INT,
    OUT result INT
)
BEGIN
    DECLARE start_subwindow BIGINT;
    DECLARE total_requests INT;

    -- Helper to insert debug logs
    DECLARE log_message TEXT;
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;
        END;

    -- Calculate the earliest subwindow within the sliding window
    SET start_subwindow = p_current_subwindow - (p_sub_window_count - 1) * (p_window_size / p_sub_window_count);
    SET log_message = CONCAT('Start subwindow: ', start_subwindow);
    INSERT INTO debug_log (log_message) VALUES (log_message);

    -- Calculate the total requests in the sliding window
    SELECT SUM(request_count)
    INTO total_requests
    FROM rate_limit_requests
    WHERE token = p_token AND subwindow >= start_subwindow;

    IF total_requests IS NULL THEN
        SET total_requests = 0;
    END IF;

    SET log_message = CONCAT('Total requests calculated: ', total_requests);
    INSERT INTO debug_log (log_message) VALUES (log_message);

    -- Check if the limit is exceeded
    IF total_requests >= p_request_limit THEN
        SET result = 0; -- Limit exceeded
        SET log_message = CONCAT('Rate limit exceeded for token: ', p_token);
        INSERT INTO debug_log (log_message) VALUES (log_message);
    ELSE
        -- Increment or insert the current subwindow count
        INSERT INTO rate_limit_requests (token, subwindow, request_count)
        VALUES (p_token, p_current_subwindow, 1)
        ON DUPLICATE KEY UPDATE request_count = request_count + 1;

        SET log_message = CONCAT('Incremented count for token: ', p_token, ' in subwindow: ', p_current_subwindow);
        INSERT INTO debug_log (log_message) VALUES (log_message);

        SET result = 1; -- Request allowed
        SET log_message = CONCAT('Request allowed for token: ', p_token);
        INSERT INTO debug_log (log_message) VALUES (log_message);
    END IF;
END
//

DELIMITER ;
