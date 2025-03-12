FROM mysql:8.4
COPY ./init_fixed_window_counter.sql /docker-entrypoint-initdb.d/init_fixed_window_counter.sql
COPY ./init_sliding_window_counter.sql /docker-entrypoint-initdb.d/init_sliding_window_counter.sql
COPY ./init_sliding_window_logs.sql /docker-entrypoint-initdb.d/init_sliding_window_logs.sql
COPY ./init_token_bucket.sql /docker-entrypoint-initdb.d/init_token_bucket.sql
COPY ./init_leaky_bucket.sql /docker-entrypoint-initdb.d/init_leaky_bucket.sql
COPY ./init_gcra.sql /docker-entrypoint-initdb.d/init_gcra.sql