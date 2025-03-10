import redis
import time

# Connect to Redis
client = redis.Redis(host='localhost', port=6379, db=0)

# Add five keys
keys_values = {
    "key1": "value1",
    "key2": "value2",
    "key3": "value3",
    "key4": "value4",
    "key5": "value5"
}

for key, value in keys_values.items():
    client.set(key, value)

print("Keys added successfully!")

# Sample keys
keys = ["key1", "key2", "key3", "key4", "key5"]

# Number of iterations to get better timing
iterations = 10000

# Measure time for individual GET commands
start_time = time.time()
for _ in range(iterations):
    for key in keys:
        client.get(key)
end_time = time.time()
get_time = (end_time - start_time) / iterations  # Average per iteration

# Measure time for a single MGET command
start_time = time.time()
for _ in range(iterations):
    client.mget(keys)
end_time = time.time()
mget_time = (end_time - start_time) / iterations  # Average per iteration

print(f"Average time taken using GET (one by one): {get_time:.6f} seconds")
print(f"Average time taken using MGET (batch): {mget_time:.6f} seconds")