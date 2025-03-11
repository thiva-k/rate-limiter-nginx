# Distributed API Rate Limiter for NGINX (OpenResty)

## Overview

This repository provides a distributed API rate-limiting solution for NGINX (OpenResty) using Redis and MySQL. It includes implementations of different rate-limiting algorithms and demonstrates their integration into an existing NGINX setup.

### Repository Contents

- **nginx/**: Contains the NGINX configuration, Lua scripts, and Docker setup.
  - **nginx.conf**: Main NGINX configuration file.
  - **lua\_scripts/**: Lua implementations of rate-limiting algorithms.
    - **mysql/**: Scripts for MySQL-based rate limiting.
    - **redis/**: Scripts for Redis-based rate limiting.
  - **Dockerfile**: Defines the OpenResty container setup.
- **docker-compose.yml**: Configuration for running the system in a containerized environment.
- **docker-compose-swarm.yml**: Configuration for deploying the system in Docker Swarm mode.


## Integration Guide

### Step 1: Clone the Repository

```sh
git clone https://github.com/your-repo/rate-limiter-nginx.git
cd rate-limiter-nginx
```

### Step 2: Configure the NGINX Rate Limiting

Modify `nginx/nginx.conf` to include rate limiting for your desired endpoints or use the existing sample TeaStore endpoints. Example:

```nginx
server {
    location /api/endpoint {
        access_by_lua_file lua_scripts/algorithm.lua;
        proxy_pass http://your_backend;
    }
}
```

### Step 3: Select and Modify the Rate-Limiting Algorithm

The repository includes six rate-limiting algorithms, with implementations for Redis and MySQL. The available algorithms are:

- Fixed Window Counter
- Sliding Window Counter
- Sliding Window Log
- Token Bucket
- Leaky Bucket
- GCRA (Generic Cell Rate Algorithm)

The Lua scripts are organized into `lua_scripts/redis/` for Redis-based algorithms and `lua_scripts/mysql/` for MySQL-based algorithms. Each folder contains separate implementations of the six algorithms.

To select an algorithm, modify the `Dockerfile` inside the `nginx/` folder to copy the appropriate script into the container. For example, to use the Redis-based Fixed Window Counter algorithm:

```dockerfile
COPY nginx/lua_scripts/redis/fixed_window_counter/fixed_window_counter_script.lua /etc/nginx/lua_scripts/algorithm.lua
```

If you prefer to use a MySQL-based algorithm, update the path accordingly:

```dockerfile
COPY nginx/lua_scripts/mysql/fixed_window_counter/fixed_window_counter_script.lua /etc/nginx/lua_scripts/algorithm.lua
```

Replace the path with the correct algorithm based on your preferred data store and rate-limiting strategy.

### Step 4: Configure Rate Limit Parameters

Rate-limiting parameters such as request rate, burst limit, expiration times, and batch quota can be modified within the selected Lua script. Example:

```lua
local rate_limit = 100  -- Requests per second
local window_size = 60  -- 60-second window
```

### Step 5: Configure Redis or MySQL Parameters

You must choose **either Redis or MySQL** as the backend for rate limiting.

- **For Redis:**

```lua
local redis_host = "redis://your-redis-host:6379"
local redis_timeout = 2000  -- Timeout in milliseconds
```

- **For MySQL:**

```lua
local mysql_host = "your-mysql-host"
local mysql_user = "your-username"
local mysql_password = "your-password"
local mysql_database = "rate_limiter"
```

### Step 6: Deploy with Docker

To run NGINX with the configured rate limiter:

```sh
docker-compose up --build
```

For Docker Swarm deployment:

```sh
docker stack deploy -c docker-compose-swarm.yml rate-limiter
```

### Asynchronous Rate Limiting (Batch Quota)

This repository also includes **asynchronous versions** for four of the algorithms: 
- Fixed Window Counter
- Sliding Window Log 
- Sliding Window Counter 
- Token Bucket 

The asynchronous implementations use a **batch-quota** concept, where instead of checking and updating the rate limit on every request, the limits are updated in bulk at regular intervals. This reduces Redis load and enhances performance, particularly for high-traffic APIs in multi-regional deployments. The `batch_quota` parameter in the Lua script determines how many requests are processed in a batch before updating to the datastore.

