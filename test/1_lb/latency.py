import requests
import time
from concurrent.futures import ThreadPoolExecutor

# Define the NGINX endpoint URLs
urls = ["http://localhost:8090/auth", "http://localhost:8090/auth"]  # Replace with your actual endpoints

# Function to send a request and print the response
def send_request(client_id, token, url, latencies):
    start_time = time.time()
    response = requests.get(url, params={"token": token})
    end_time = time.time()
    latency = end_time - start_time
    latencies.append(latency)
    print(f"Client {client_id} - Token {token} - URL {url} - Status Code: {response.status_code} - Latency: {latency:.4f} seconds")

# Test the latency of sending requests
def test_latency(num_clients, num_requests):
    tokens = [f"token_{i}" for i in range(num_clients)]  # Generate unique tokens for each client
    latencies = []

    with ThreadPoolExecutor(max_workers=num_clients) as executor:
        for _ in range(num_requests):
            futures = [executor.submit(send_request, client_id, tokens[client_id], urls[client_id % len(urls)], latencies) for client_id in range(num_clients)]
            for future in futures:
                future.result()

    # Calculate and print latency
    total_requests = len(latencies)
    total_time = sum(latencies)
    average_latency = total_time / total_requests if total_requests > 0 else 0

    print(f"\nTotal requests: {total_requests}")
    print(f"Total time: {total_time:.4f} seconds")
    print(f"Average latency: {average_latency:.4f} seconds")

if __name__ == "__main__":
    num_clients = 2  # Number of concurrent clients
    num_requests = 1000  # Number of requests per client
    test_latency(num_clients, num_requests)