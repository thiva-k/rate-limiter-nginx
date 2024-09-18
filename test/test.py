import requests
import time

# Define the NGINX endpoint URL
url = "http://localhost:8090/auth?token=kobi"  # Replace with your actual endpoint

# Define the token parameter
token = "test_token"

# Function to send a request and print the response
def send_request():
    response = requests.get(url, params={"token": token})
    print(f"Status Code: {response.status_code}")

# Test the rate-limiting algorithm
def test_rate_limiter():
    # Send initial requests to deplete the tokens
    print("Sending initial requests to deplete tokens:")
    for _ in range(10):
        send_request()
        time.sleep(0.1)  # Short delay between requests

    # Send a request that should be rate-limited
    print("Sending a request that should be rate-limited:")
    send_request()

    # Wait for tokens to refill
    print("Waiting for tokens to refill...")
    time.sleep(2)  # Wait for 10 seconds to allow tokens to refill

    # Send a request that should be allowed
    print("Sending a request that should be allowed:")
    send_request()

if __name__ == "__main__":
    test_rate_limiter()