ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

USE rate_limit_db;

CREATE TABLE rate_limit_gcra (
    token VARCHAR(255) PRIMARY KEY,
    tat DOUBLE
);
