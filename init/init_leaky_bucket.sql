-- Create the database
CREATE DATABASE IF NOT EXISTS rate_limit_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
-- Switch to the database
USE rate_limit_db;

-- Create the leaky bucket table
CREATE TABLE IF NOT EXISTS rate_limit (
    token VARCHAR(255) PRIMARY KEY,   -- The token used for rate limiting
    tokens INT DEFAULT 0,            -- Current number of tokens in the bucket
    last_access DOUBLE DEFAULT 0    -- The last time the bucket was updated (UNIX timestamp in seconds)
);

-- Optional: Debug log table for tracking actions
CREATE TABLE IF NOT EXISTS debug_log (
    id INT AUTO_INCREMENT PRIMARY KEY,
    message TEXT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
);


-- Drop the procedure if it exists
DROP PROCEDURE IF EXISTS LeakyBucketRateLimit;

-- Create the procedure
DELIMITER //

CREATE PROCEDURE LeakyBucketRateLimit(
    IN p_token VARCHAR(255),         -- Input: The token
    IN p_bucket_capacity INT,        -- Input: Maximum tokens in the bucket
    IN p_leak_rate INT,              -- Input: Tokens leaked per second
    IN p_requested_tokens INT,       -- Input: Tokens required per request
    OUT p_status VARCHAR(20)         -- Output: Result status (ALLOWED/TOO_MANY_REQUESTS)
)
BEGIN
    DECLARE v_current_time BIGINT;     -- Current time in milliseconds
    DECLARE v_elapsed_time BIGINT;     -- Elapsed time since last access
    DECLARE v_leaked_tokens INT;       -- Tokens leaked since last access
    DECLARE v_new_token_level INT;     -- Updated token level
    DECLARE v_last_access BIGINT;      -- Last access timestamp
    DECLARE v_tokens INT;              -- Current tokens in the bucket
    DECLARE v_internal_status VARCHAR(20); -- Internal status variable

    -- Get the current timestamp in milliseconds
    SET v_current_time = UNIX_TIMESTAMP() * 1000;

    -- Fetch the current state of the token
    SELECT tokens, last_access
    INTO v_tokens, v_last_access
    FROM rate_limit
    WHERE token = p_token
    FOR UPDATE;

    -- If no record exists for the token, initialize it
    IF v_tokens IS NULL THEN
        SET v_tokens = 0;
        SET v_last_access = v_current_time;

        INSERT INTO rate_limit (token, tokens, last_access)
        VALUES (p_token, v_tokens, v_last_access);
    END IF;

    -- Calculate the elapsed time since the last access
    SET v_elapsed_time = v_current_time - v_last_access;

    -- Calculate the number of leaked tokens
    SET v_leaked_tokens = FLOOR(v_elapsed_time * p_leak_rate / 1000);

    -- Update the token level by applying the leaked tokens
    SET v_new_token_level = GREATEST(0, v_tokens - v_leaked_tokens);

    -- Determine if the request can be allowed
    IF v_new_token_level + p_requested_tokens <= p_bucket_capacity THEN
        -- Allow the request and increment the token level
        SET v_new_token_level = v_new_token_level + p_requested_tokens;
        SET v_internal_status = 'ALLOWED';
    ELSE
        -- Deny the request
        SET v_internal_status = 'TOO_MANY_REQUESTS';
    END IF;

    -- Update the rate limit record
    UPDATE rate_limit
    SET tokens = v_new_token_level, last_access = v_current_time
    WHERE token = p_token;

    -- Assign the internal status to the OUT parameter
    SET p_status = v_internal_status;

    -- Log the operation for debugging (optional)
    INSERT INTO debug_log (message)
    VALUES (CONCAT(
        'Token=', p_token,
        ', Status=', p_status,
        ', Tokens=', v_new_token_level,
        ', LastAccess=', v_current_time
    ));
END;
//

DELIMITER ;
