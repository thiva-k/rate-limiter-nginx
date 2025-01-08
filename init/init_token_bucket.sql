CREATE DATABASE IF NOT EXISTS rate_limit_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
-- Switch to the database
USE rate_limit_db;

CREATE TABLE rate_limit (
    token VARCHAR(255) PRIMARY KEY,
    tokens FLOAT NOT NULL,
    last_access BIGINT NOT NULL
);
