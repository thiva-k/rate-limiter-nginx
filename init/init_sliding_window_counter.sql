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
