import requests
import time
from concurrent.futures import ThreadPoolExecutor

# Define the NGINX endpoint URL
url = "http://localhost:8090/auth"  # Replace with your actual endpoint

# Function to send a request and print the response
def send_request(client_id, token, latencies):
    start_time = time.time()
    response = requests.get(url, params={"token": token})
    end_time = time.time()
    latency = end_time - start_time
    latencies.append(latency)
    print(f"Client {client_id} - Token {token} - Status Code: {response.status_code} - Latency: {latency:.4f} seconds")

# Test the rate-limiting algorithm with multiple clients
def test_rate_limiter_concurrent(num_clients):
    tokens = [f"token_{i}" for i in range(num_clients)]  # Generate unique tokens for each client
    latencies = []

    with ThreadPoolExecutor(max_workers=num_clients) as executor:
        # Send initial requests to deplete the tokens
        print("Sending initial requests to deplete tokens:")
        for _ in range(10):  # Send 10 requests per client
            futures = [executor.submit(send_request, client_id, tokens[client_id], latencies) for client_id in range(num_clients)]
            for future in futures:
                future.result()
            time.sleep(0.1)  # Short delay between requests

        # Send a request that should be rate-limited
        print("Sending requests that should be rate-limited:")
        futures = [executor.submit(send_request, client_id, tokens[client_id], latencies) for client_id in range(num_clients)]
        for future in futures:
            future.result()

        # Wait for tokens to refill
        print("Waiting for tokens to refill...")
        time.sleep(2)  # Wait for 2 seconds to allow tokens to refill

        # Send a request that should be allowed
        print("Sending requests that should be allowed:")
        futures = [executor.submit(send_request, client_id, tokens[client_id], latencies) for client_id in range(num_clients)]
        for future in futures:
            future.result()

    # Calculate and print latency and throughput
    total_requests = len(latencies)
    total_time = sum(latencies)
    average_latency = total_time / total_requests if total_requests > 0 else 0
    throughput = total_requests / total_time if total_time > 0 else 0

    print(f"\nTotal requests: {total_requests}")
    print(f"Total time: {total_time:.4f} seconds")
    print(f"Average latency: {average_latency:.4f} seconds")
    print(f"Throughput: {throughput:.4f} requests/second")

if __name__ == "__main__":
    num_clients = 10  # Number of concurrent clients
    test_rate_limiter_concurrent(num_clients)