-- Set authentication to native password
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

-- Use the rate_limit_db
USE rate_limit_db;

-- Create the sliding window table with improvements
CREATE TABLE rate_limit_sliding_window (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,  -- Auto-incrementing primary key
    token VARCHAR(255) NOT NULL,           -- Token for each user/client
    request_time DOUBLE NOT NULL,          -- Store request time in seconds
    INDEX (token, request_time)            -- Index for fast querying by token and time
);
