-- Allow root user to connect from any host with password authentication
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

-- Create the rate_limiter database if it doesn't exist
CREATE DATABASE IF NOT EXISTS rate_limiter;

-- Use the rate_limiter database
USE rate_limiter;

-- Create the rate_limits table
CREATE TABLE IF NOT EXISTS rate_limits (
    id INT AUTO_INCREMENT PRIMARY KEY,
    token VARCHAR(255) NOT NULL UNIQUE,
    request_timestamps JSON NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- Create an index on the token column for faster lookups
CREATE INDEX idx_token ON rate_limits (token);

-- Insert a default token with an empty timestamps array
INSERT INTO rate_limits (token, request_timestamps) VALUES
    ('default_token', '[]')
ON DUPLICATE KEY UPDATE request_timestamps = VALUES(request_timestamps);

-- Grant privileges to the 'user' account (adjust as needed)
GRANT ALL PRIVILEGES ON