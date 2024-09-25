-- Change authentication method for root user
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';

USE rate_limit_db;

CREATE TABLE IF NOT EXISTS rate_limit_entries (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    token VARCHAR(255) NOT NULL,
    timestamp DOUBLE NOT NULL,
    INDEX idx_token_timestamp (token, timestamp)
) ENGINE=InnoDB;

DELIMITER //

CREATE EVENT IF NOT EXISTS cleanup_old_entries
ON SCHEDULE EVERY 1 MINUTE
DO
BEGIN
    DELETE FROM rate_limit_entries
    WHERE timestamp < UNIX_TIMESTAMP() - 60;
END //

DELIMITER ;

SET GLOBAL event_scheduler = ON;


