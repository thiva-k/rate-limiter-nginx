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
def test_rate_limiter_concurrent(num_requests_per_user, num_users):
    tokens = [f"token_{i}" for i in range(num_users)]  # Generate unique tokens for each user
    latencies = []
    staus_codes = []
    with ThreadPoolExecutor(max_workers=num_requests_per_user * num_users) as executor:
        # Send requests concurrently for each user
        print("Sending requests concurrently for each user:")
        futures = []
        for user_id in range(num_users):
            for request_id in range(num_requests_per_user):
                futures.append(executor.submit(send_request, user_id, tokens[user_id], urls[user_id % 2], latencies))
        
        for future in futures:
            staus_codes.append(future.result())
            future.result()


    return latencies, staus_codes

if __name__ == "__main__":
    num_requests_per_user = 10  # Number of requests per user
    num_users = 1 # Number of users

    print(f"Running test with {num_users} users, each sending {num_requests_per_user} requests concurrently.")
    latencies, staus_codes = test_rate_limiter_concurrent(num_requests_per_user, num_users)
    
    # Calculate and print latency and throughput
    total_requests = len(latencies)
    total_time = sum(latencies)
    average_latency = total_time / total_requests if total_requests > 0 else 0
    throughput = total_requests / total_time if total_time > 0 else 0
    error_500 = staus_codes.count(500)
    error_429 = staus_codes.count(429)
    success = staus_codes.count(200)
    print(f"\nNumber of 500 errors: {error_500}")
    print(f"Number of 429 errors: {error_429}")
    print(f"Number of successful requests: {success}")

    print(f"\nTotal requests: {total_requests}")
    print(f"Total time: {total_time:.4f} seconds")
    print(f"Average latency: {average_latency:.4f} seconds")
    print(f"Throughput: {throughput:.4f} requests/second")