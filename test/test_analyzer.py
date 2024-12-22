import pandas as pd

# Configuration
warm_up_period = 0.5 * 60 * 1000  # 2 minutes in milliseconds (adjustable)
file_path = "jmeter_results.csv"  # Replace with your file path
output_file = "statistics_results.csv"  # File to save the statistics

# Load CSV data
data = pd.read_csv(file_path)
data.columns = [
    "timeStamp", "elapsed", "label", "responseCode", "responseMessage", "threadName", 
    "dataType", "success", "failureMessage", "bytes", "sentBytes", "grpThreads", 
    "allThreads", "URL", "Latency", "IdleTime", "Connect"
]

# Convert timestamps to relative time for filtering
start_time = data["timeStamp"].min()
data["relativeTime"] = data["timeStamp"] - start_time

# Filter out warm-up period requests
filtered_data = data[data["relativeTime"] > warm_up_period]

# Extract user identifiers (e.g., from threadName or tokens in the URL)
filtered_data["user"] = filtered_data["URL"].str.extract(r'token=([^&]+)')

# Calculate per-user statistics
def calculate_user_stats(group):
    total_requests = len(group)
    total_errors = len(group[group["success"] == False])
    total_time = (group["relativeTime"].max() - group["relativeTime"].min()) / 1000
    throughput = total_requests / total_time if total_time > 0 else 0
    avg_latency = group["Latency"].mean()
    error_rate = (total_errors / total_requests) * 100 if total_requests > 0 else 0

    return pd.Series({
        "throughput": throughput,
        "avg_latency": avg_latency,
        "error_rate": error_rate
    })

user_stats = filtered_data.groupby("user", group_keys=False).apply(calculate_user_stats, include_groups=False)

# Calculate overall server statistics
server_throughput = len(filtered_data) / ((filtered_data["relativeTime"].max() - filtered_data["relativeTime"].min()) / 1000)
avg_server_latency = filtered_data["Latency"].mean()

# Additional Details
num_users = filtered_data["user"].nunique()
total_test_time = (data["timeStamp"].max() - data["timeStamp"].min()) / 1000  # in seconds
total_time_considered = (filtered_data["relativeTime"].max() - filtered_data["relativeTime"].min()) / 1000  # in seconds

# Save results to a file
user_stats["server_throughput"] = server_throughput
user_stats["avg_server_latency"] = avg_server_latency
user_stats.to_csv(output_file)

# Output results
print("Per-User Statistics saved to", output_file)
print("\nOverall Server Statistics:\n")
print(f"Throughput: {server_throughput:.2f} requests/sec")
print(f"Average Latency: {avg_server_latency:.2f} ms")

print("\nAdditional Details:\n")
print(f"Total Users: {num_users}")
print(f"Total Test Run Time: {total_test_time:.2f} seconds")
print(f"Total Time Considered for Test: {total_time_considered:.2f} seconds")
