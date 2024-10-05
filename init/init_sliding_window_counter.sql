-- Set authentication to native password
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

-- Use the rate_limit_db
USE rate_limit_db;

CREATE TABLE request_limits (
    token VARCHAR(255) PRIMARY KEY,
    last_access DATETIME,
    sub_windows JSON
);
