import requests
import time
from concurrent.futures import ThreadPoolExecutor

# Define the NGINX endpoint URL
url = "http://localhost:8090/auth"  # Replace with your actual endpoint

# Function to send a request and print the response
def send_request(client_id, token):
    response = requests.get(url, params={"token": token})
    print(f"Client {client_id} - Token {token} - Status Code: {response.status_code}")

# Test the rate-limiting algorithm with multiple clients
def test_rate_limiter_concurrent(num_clients):
    tokens = [f"token_{i}" for i in range(num_clients)]  # Generate unique tokens for each client

    with ThreadPoolExecutor(max_workers=num_clients) as executor:
        # Send initial requests to deplete the tokens
        print("Sending initial requests to deplete tokens:")
        for _ in range(10):  # Send 10 requests per client
            futures = [executor.submit(send_request, client_id, tokens[client_id]) for client_id in range(num_clients)]
            for future in futures:
                future.result()
            time.sleep(0.1)  # Short delay between requests

        # Send a request that should be rate-limited
        print("Sending requests that should be rate-limited:")
        futures = [executor.submit(send_request, client_id, tokens[client_id]) for client_id in range(num_clients)]
        for future in futures:
            future.result()

        # Wait for tokens to refill
        print("Waiting for tokens to refill...")
        time.sleep(2)  # Wait for 2 seconds to allow tokens to refill

        # Send a request that should be allowed
        print("Sending requests that should be allowed:")
        futures = [executor.submit(send_request, client_id, tokens[client_id]) for client_id in range(num_clients)]
        for future in futures:
            future.result()

if __name__ == "__main__":
    num_clients = 10  # Number of concurrent clients
    test_rate_limiter_concurrent(num_clients)