import requests
import time
from concurrent.futures import ThreadPoolExecutor

# Define the NGINX endpoint URL
url = "http://localhost:8090/tools.descartes.teastore.persistence/rest/categories?start=-1&max=-1"  # Replace with your actual endpoint

count_200 = 0
count_429 = 0

# Function to send a request and print the response
def send_request(client_id, token):
    response = requests.get(url, params={"token": token})
    current_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()) + f".{int((time.time() % 1) * 1_000_000):06d}"
    if response.status_code == 200:
        global count_200
        count_200 += 1
    elif response.status_code == 429:
        global count_429
        count_429 += 1
    print(f"{current_time} - Client {client_id} - Token {token} - Status Code: {response.status_code}")

# Test the rate-limiting algorithm with multiple clients
def test_rate_limiter_concurrent(num_clients):
    tokens = [f"token_{i}" for i in range(num_clients)]  # Generate unique tokens for each client

    with ThreadPoolExecutor(max_workers=num_clients) as executor:
        # Send initial requests to dep`lete the tokens
        print("Sending initial requests to deplete tokens:")
        for _ in range(192):  # Send 10 requests per client
            futures = [executor.submit(send_request, client_id, tokens[client_id]) for client_id in range(num_clients)]
            for future in futures:
                future.result()
            time.sleep(0.3)  # Short delay between requests
        
        print(f"200: {count_200}")
        print(f"429: {count_429}")

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
    num_clients = 1  # Number of concurrent clients
    test_rate_limiter_concurrent(num_clients)