import requests
import time
from concurrent.futures import ThreadPoolExecutor

# Define the NGINX endpoint URLs
urls = ["http://localhost:8090/tools.descartes.teastore.persistence/rest/categories?start=-1&max=-1", 
        "http://localhost:8091/tools.descartes.teastore.persistence/rest/categories?start=-1&max=-1"]

# Function to send a request and print the response
def send_request(client_id, token, url, latencies):
    start_time = time.time()
    response = requests.get(url, params={"token": token})
    end_time = time.time()
    latency = end_time - start_time
    latencies.append(latency)
    current_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()) + f".{int((time.time() % 1) * 1_000_000):06d}"
    print(f"{current_time} - Client {client_id} - Token {token} - Status Code: {response.status_code} - Latency: {latency:.6f} seconds")
    return response.status_code

# Test the rate-limiting algorithm with multiple requests from multiple users
def test_rate_limiter_concurrent(num_requests, num_users):
    tokens = [f"token_{i}" for i in range(num_users)]  # Generate unique tokens for each user
    latencies = []

    with ThreadPoolExecutor(max_workers=num_requests) as executor:
        # Send initial requests to deplete the tokens
        print("Sending initial requests to deplete tokens:")
        for _ in range(num_users):
            futures = [
                executor.submit(send_request, request_id, tokens[request_id % num_users], urls[request_id % 2], latencies) 
                    for request_id in range(num_requests)
                ]
            for future in futures:
                future.result()

        # Send a request that should be rate-limited
        print("Sending requests that should be rate-limited:")
        for _ in range(num_users):
            futures = [
                executor.submit(send_request, request_id, tokens[request_id % num_users], urls[request_id % 2], latencies) 
                for request_id in range(num_requests)]
            for future in futures:
                future.result()

        # Wait for tokens to refill
        print("Waiting for tokens to refill...")
        time.sleep(10)  # Wait for 10 seconds to allow tokens to refill

        # Send a request that should be allowed
        print("Sending requests that should be allowed:")
        for _ in range(num_users):
            futures = [
                executor.submit(send_request, request_id, tokens[request_id % num_users], urls[request_id % 2], latencies) 
                for request_id in range(num_requests)]
            for future in futures:
                future.result()

    return latencies

if __name__ == "__main__":
    num_requests = 10 # Number of concurrent requests
    num_runs = 1  # Number of times to run the test
    num_users = 1  # Number of users

    all_latencies = []

    for run in range(num_runs):
        print(f"Running test iteration {run + 1}/{num_runs}")
        latencies = test_rate_limiter_concurrent(num_requests, num_users)
        all_latencies.extend(latencies)
        
        # Wait for tokens to replenish before the next iteration
        print("Waiting for tokens to replenish before the next iteration...")
        time.sleep(10)

    # Calculate and print latency and throughput
    total_requests = len(all_latencies)
    total_time = sum(all_latencies)
    average_latency = total_time / total_requests if total_requests > 0 else 0
    throughput = total_requests / (num_runs * 10 + total_time) if total_time > 0 else 0

    print(f"\nTotal requests: {total_requests}")
    print(f"Total time: {total_time:.4f} seconds")
    print(f"Average latency: {average_latency:.4f} seconds")
    print(f"Throughput: {throughput:.4f} requests/second")