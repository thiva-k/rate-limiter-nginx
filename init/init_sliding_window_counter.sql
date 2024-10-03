-- Set authentication to native password
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

-- Use the rate_limit_db
USE rate_limit_db;

CREATE TABLE sliding_window_counter (
    token VARCHAR(255) NOT NULL,
    bucket INT NOT NULL, -- Stores the time bucket, based on granularity
    request_count INT DEFAULT 0, -- Counter for the number of requests in the bucket
    PRIMARY KEY (token, bucket)
);
