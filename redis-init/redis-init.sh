#!/bin/bash
# Set rate limits and throttle limits for tiers
redis-cli -h redis -p 6379 HSET tiers gold:rate_limit:api1 10
redis-cli -h redis -p 6379 HSET tiers gold:rate_limit:api2 20
redis-cli -h redis -p 6379 HSET tiers gold:throttle_limit:api1 1500
redis-cli -h redis -p 6379 HSET tiers gold:throttle_limit:api2 2500
redis-cli -h redis -p 6379 HSET tiers silver:rate_limit:api1 5
redis-cli -h redis -p 6379 HSET tiers silver:rate_limit:api2 15
redis-cli -h redis -p 6379 HSET tiers silver:throttle_limit:api1 1000
redis-cli -h redis -p 6379 HSET tiers silver:throttle_limit:api2 2000
redis-cli -h redis -p 6379 HSET tiers platinum:rate_limit:api1 20
redis-cli -h redis -p 6379 HSET tiers platinum:rate_limit:api2 30
redis-cli -h redis -p 6379 HSET tiers platinum:throttle_limit:api1 5000
redis-cli -h redis -p 6379 HSET tiers platinum:throttle_limit:api2 3000
redis-cli -h redis -p 6379 HSET tiers free:rate_limit:api1 1
redis-cli -h redis -p 6379 HSET tiers free:rate_limit:api2 2
redis-cli -h redis -p 6379 HSET tiers free:throttle_limit:api1 100
redis-cli -h redis -p 6379 HSET tiers free:throttle_limit:api2 200
# Set token-tier mapping
redis-cli -h redis -p 6379 HSET token_tier_mapping token1 silver
redis-cli -h redis -p 6379 HSET token_tier_mapping token2 gold
redis-cli -h redis -p 6379 HSET token_tier_mapping token3 platinum
