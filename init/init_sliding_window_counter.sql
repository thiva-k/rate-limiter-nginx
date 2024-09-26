ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

USE rate_limit_db;

CREATE TABLE rate_limit_sliding_window (
    token VARCHAR(255),
    request_time DOUBLE,
    PRIMARY KEY (token, request_time)
);
