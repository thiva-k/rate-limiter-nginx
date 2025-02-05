CREATE DATABASE IF NOT EXISTS rate_limit_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
-- Switch to the database
USE rate_limit_db;

CREATE TABLE rate_limit (
    token VARCHAR(255) PRIMARY KEY,
    tokens FLOAT NOT NULL,
    last_access BIGINT NOT NULL
);


DELIMITER //

CREATE PROCEDURE rate_limit(
    IN token VARCHAR(255),
    IN bucket_capacity INT,
    IN refill_rate FLOAT,
    IN requested_tokens INT,
    OUT allowed INT
)
BEGIN
    DECLARE now BIGINT;
    DECLARE elapsed BIGINT;
    DECLARE add_tokens FLOAT;
    DECLARE new_tokens FLOAT;
    DECLARE last_tokens FLOAT DEFAULT bucket_capacity;
    DECLARE last_access BIGINT;

    -- Get current timestamp in milliseconds
    SET now = UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000;

    -- Fetch current token state
    SELECT tokens, last_access INTO last_tokens, last_access
    FROM rate_limit
    WHERE token = token
    FOR UPDATE;

    -- If no record exists, initialize it
    IF last_access IS NULL THEN
        SET last_tokens = bucket_capacity;
        SET last_access = now;

        INSERT INTO rate_limit (token, tokens, last_access)
        VALUES (token, bucket_capacity, now)
        ON DUPLICATE KEY UPDATE tokens = VALUES(tokens), last_access = VALUES(last_access);
    END IF;

    -- Calculate elapsed time and refill tokens
    SET elapsed = now - last_access;
    SET add_tokens = elapsed * refill_rate / 1000;
    SET new_tokens = LEAST(bucket_capacity, last_tokens + add_tokens);

    -- Check if request can be allowed
    IF new_tokens >= requested_tokens THEN
        SET new_tokens = new_tokens - requested_tokens;
        SET allowed = 1;

        -- Update token count and last access time
        UPDATE rate_limit
        SET tokens = new_tokens, last_access = now
        WHERE token = token;
    ELSE
        SET allowed = 0;
    END IF;
END;
//

DELIMITER ;
