FROM redis:latest

COPY redis-init.sh /redis-init.sh
RUN chmod +x /redis-init.sh

CMD ["sh", "-c", "while ! redis-cli -h redis -p 6379 ping; do echo 'Waiting for Redis...'; sleep 1; done; /redis-init.sh; exit 0"]
