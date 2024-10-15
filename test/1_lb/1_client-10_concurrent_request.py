import requests
import time
from concurrent.futures import ThreadPoolExecutor

# Define the NGINX endpoint URL
url = "http://localhost:8090/auth"  # Replace with your actual endpoint

# Function to send a request and print the response
def send_request(client_id, token):
    response = requests.get(url, params={"token": token})
    current_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()) + f".{int((time.time() % 1) * 1_000_000):06d}"
    print(f"{current_time} - Client {client_id} - Token {token} - Status Code: {response.status_code}")

# Test the rate-limiting algorithm with multiple requests from the same user
def test_rate_limiter_concurrent_same_user(num_requests):
    token = "test_token"  # Use the same token for all requests

    with ThreadPoolExecutor(max_workers=num_requests) as executor:
        # Send initial requests to deplete the tokens
        print("Sending initial requests to deplete tokens:")
        futures = [executor.submit(send_request, request_id, token) for request_id in range(num_requests)]
        for future in futures:
            future.result()
        time.sleep(0.1)  # Short delay between requests

        # Send a request that should be rate-limited
        print("Sending requests that should be rate-limited:")
        futures = [executor.submit(send_request, request_id, token) for request_id in range(num_requests)]
        for future in futures:
            future.result()

        # Wait for tokens to refill
        print("Waiting for tokens to refill...")
        time.sleep(10)  # Wait for 10 seconds to allow tokens to refill

        # Send a request that should be allowed
        print("Sending requests that should be allowed:")
        futures = [executor.submit(send_request, request_id, token) for request_id in range(num_requests)]
        for future in futures:
            future.result()

if __name__ == "__main__":
    num_requests = 10  # Number of concurrent requests
    test_rate_limiter_concurrent_same_user(num_requests)