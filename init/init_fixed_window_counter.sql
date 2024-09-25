ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

USE rate_limit_db;

CREATE TABLE IF NOT EXISTS rate_limit_fixed_window (
    token VARCHAR(255) NOT NULL PRIMARY KEY,
    count INT NOT NULL,
    expires_at DOUBLE NOT NULL
);
