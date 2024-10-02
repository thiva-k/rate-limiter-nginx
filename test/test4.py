import requests
import time
from concurrent.futures import ThreadPoolExecutor

# Define the NGINX endpoint URL
url = "http://localhost:8090/auth"  # Replace with your actual endpoint

# Function to send a request and print the response
def send_request(client_id, token):
    response = requests.get(url, params={"token": token})
    print(f"Client {client_id} - Token {token} - Status Code: {response.status_code}")
    return response.status_code

# Test the rate-limiting algorithm with multiple requests from the same user
def test_rate_limiter_concurrent_same_user(num_requests):
    token = "test_token"  # Use the same token for all requests
    passed = True

    with ThreadPoolExecutor(max_workers=num_requests) as executor:
        # Send initial requests to deplete the tokens
        print("Sending initial requests to deplete tokens:")
        futures = [executor.submit(send_request, request_id, token) for request_id in range(num_requests)]
        for future in futures:
            if future.result() != 200:
                passed = False
        time.sleep(0.1)  # Short delay between requests

        # Send a request that should be rate-limited
        print("Sending requests that should be rate-limited:")
        futures = [executor.submit(send_request, request_id, token) for request_id in range(num_requests)]
        for future in futures:
            if future.result() != 429:
                passed = False

        # Wait for tokens to refill
        print("Waiting for tokens to refill...")
        time.sleep(10)  # Wait for 10 seconds to allow tokens to refill

        # Send a request that should be allowed
        print("Sending requests that should be allowed:")
        futures = [executor.submit(send_request, request_id, token) for request_id in range(num_requests)]
        for future in futures:
            if future.result() != 200:
                passed = False

    return passed

if __name__ == "__main__":
    num_requests = 10  # Number of concurrent requests
    num_runs = 10  # Number of times to run the test

    results = []

    for run in range(num_runs):
        print(f"Running test iteration {run + 1}/{num_runs}")
        result = test_rate_limiter_concurrent_same_user(num_requests)
        results.append(result)
        if result:
            print(f"Test iteration {run + 1} passed")
        else:
            print(f"Test iteration {run + 1} failed")
        
        # Wait for tokens to replenish before the next iteration
        print("Waiting for tokens to replenish before the next iteration...")
        time.sleep(10)

    # Summary of test results
    passed_tests = sum(results)
    failed_tests = num_runs - passed_tests
    print("\nSummary of test results:")
    print(f"Total iterations: {num_runs}")
    print(f"Passed iterations: {passed_tests}")
    print(f"Failed iterations: {failed_tests}")