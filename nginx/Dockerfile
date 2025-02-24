FROM openresty/openresty:alpine

# Create a directory to store Lua scripts
RUN mkdir -p /usr/local/openresty/nginx/lua_scripts

# Copy the Lua script to the container
COPY lua_scripts/redis/sliding_window_logs/sliding_window_logs_async_v2.lua /usr/local/openresty/nginx/lua_scripts/algorithm.lua

# Copy the nginx configuration file
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
