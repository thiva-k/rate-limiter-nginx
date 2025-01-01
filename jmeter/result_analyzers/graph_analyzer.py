import pandas as pd
import matplotlib.pyplot as plt

# Configuration
file_path = "D:/Semester 7/CS4203 - Research and Development Project/Artifacts/rate-limiter-nginx/jmeter/jmeter_results.csv"
output_file = "D:/Semester 7/CS4203 - Research and Development Project/Artifacts/rate-limiter-nginx/jmeter/results_analyzer/transactions_per_second.png"
granularity = '1min'  # Granularity for resampling (e.g., '30S' for 30 seconds, '1min' for 1 minute)

# Specify data types for columns
dtype = {
    'timeStamp': 'int64',
    'elapsed': 'int64',
    'label': 'str',
    'responseCode': 'str',
    'responseMessage': 'str',
    'threadName': 'str',
    'dataType': 'str',
    'success': 'bool',
    'failureMessage': 'str',
    'bytes': 'int64',
    'sentBytes': 'int64',
    'grpThreads': 'int64',
    'allThreads': 'int64',
    'URL': 'str',
    'Latency': 'int64',
    'IdleTime': 'int64',
    'Connect': 'int64'
}

# Load CSV data with specified data types
data = pd.read_csv(file_path, dtype=dtype, low_memory=False)

# Convert timestamp to datetime
data['timeStamp'] = pd.to_datetime(data['timeStamp'], unit='ms')

# Resample data to specified granularity and count transactions
transactions_per_interval = data.resample(granularity, on='timeStamp').size()

# Convert transactions per interval to transactions per second
interval_seconds = pd.to_timedelta(granularity).total_seconds()
transactions_per_second = transactions_per_interval / interval_seconds

# Calculate the maximum transactions per second
max_transactions_per_second = transactions_per_second.max()
print(f"Max Transactions Per Second: {max_transactions_per_second}")

# Plot the data
plt.figure(figsize=(10, 6))
plt.plot(transactions_per_second.index, transactions_per_second.values, marker='o')
plt.title('Total Transactions Per Second')
plt.xlabel('Time')
plt.ylabel('Transactions Per Second')
plt.grid(True)
plt.savefig(output_file)
plt.show()