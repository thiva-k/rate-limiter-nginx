#!/bin/bash

# Set rate limits and throttle limits for tiers
redis-cli -h redis -p 6379 HMSET tiers \
    gold:rate_limit:api1 10 gold:rate_limit:api2 20 gold:throttle_limit:api1 1500 gold:throttle_limit:api2 2500 \
    silver:rate_limit:api1 5 silver:rate_limit:api2 15 silver:throttle_limit:api1 1000 silver:throttle_limit:api2 2000 \
    platinum:rate_limit:api1 20 platinum:rate_limit:api2 30 platinum:throttle_limit:api1 5000 platinum:throttle_limit:api2 3000 \
    free:rate_limit:api1 1 free:rate_limit:api2 2 free:throttle_limit:api1 100 free:throttle_limit:api2 200

# Set token-tier mapping
redis-cli -h redis -p 6379 HMSET token_tier_mapping \
    token1 silver \
    token2 gold \
    token3 platinum
