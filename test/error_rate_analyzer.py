import pandas as pd
from datetime import datetime

# Configuration Variables
FILE_PATH = "C:/Users/ASUS/Desktop/Repos/rate-limiter-nginx/test/jmeter_results.csv"
RATE_LIMIT = 100  # Maximum requests allowed per window
WINDOW_SIZE = 60  # Window size in seconds

# Output file names
ERROR_DETAILS_FILE = "./test/error_details.csv"
CLIENT_STATS_FILE = "./test/client_stats.csv"
OVERALL_STATS_FILE = "./test/overall_stats.csv"

def analyze_rate_limiting(file_path, rate_limit=100, window_size=60):
    """
    Analyze rate limiting logs for API requests with rolling window logic.

    Parameters:
        file_path (str): Path to the CSV file containing logs.
        rate_limit (int): Maximum number of allowed requests per window.
        window_size (int): Size of the window in seconds (default is 60 seconds).

    Returns:
        tuple: DataFrames and statistics including:
            - client_stats: Aggregated statistics per client.
            - overall_stats: Overall aggregated statistics.
            - error_details: Details of errors.
    """
    # Load and prepare data
    data = pd.read_csv(file_path)
    data.columns = [
        "timeStamp", "elapsed", "label", "responseCode", "responseMessage", "threadName", 
        "dataType", "success", "failureMessage", "bytes", "sentBytes", "grpThreads", 
        "allThreads", "URL", "Latency", "IdleTime", "Connect"
    ]

    # Convert timestamps to datetime and calculate relative time
    data['datetime'] = pd.to_datetime(data['timeStamp'], unit='ms')
    data['client_id'] = data['URL'].str.extract(r'token=([^&]+)')

    # Initialize error logging
    errors = []

    # Analyze each client
    clients = data['client_id'].unique()
    client_stats = []

    for client_id in clients:
        client_data = data[data['client_id'] == client_id].sort_values('timeStamp')
        total_requests = len(client_data)
        total_errors = 0

        for i in range(len(client_data)):
            request = client_data.iloc[i]
            current_time = request['timeStamp']

            # Define rolling window
            start_time = current_time - (window_size * 1000)
            end_time = current_time

            # Requests in the rolling window
            window_requests = client_data[
                (client_data['timeStamp'] > start_time) &
                (client_data['timeStamp'] < end_time) 
            ]

            successful_requests = len(window_requests[window_requests['responseCode'] == 200])

            # Determine expected response
            expected_response = 200 if successful_requests < rate_limit else 429

            # Compare with actual response
            actual_response = request['responseCode']
            if actual_response != expected_response:
                total_errors += 1
                errors.append({
                    'client_id': client_id,
                    'timestamp': request['timeStamp'],
                    'actual_response': actual_response,
                    'expected_response': expected_response,
                    'window_start': start_time,
                    'window_end': end_time
                })

        # Summarize statistics for the client
        client_stats.append({
            'client_id': client_id,
            'total_requests': total_requests,
            'total_errors': total_errors,
            'error_rate': (total_errors / total_requests) * 100 if total_requests > 0 else 0
        })

    # Aggregate overall statistics
    client_stats_df = pd.DataFrame(client_stats)
    overall_stats = {
        'total_clients': len(client_stats_df),
        'total_requests': client_stats_df['total_requests'].sum(),
        'total_errors': client_stats_df['total_errors'].sum(),
        'avg_error_rate': client_stats_df['error_rate'].mean()
    }

    # Save errors
    error_details_df = pd.DataFrame(errors) if errors else pd.DataFrame()
    if not error_details_df.empty:
        error_details_df.to_csv(ERROR_DETAILS_FILE, index=False)

    return client_stats_df, overall_stats, error_details_df

def save_and_print_results(client_stats, overall_stats, error_details):
    """Save results to CSV and print summary."""
    client_stats.to_csv(CLIENT_STATS_FILE, index=False)
    pd.DataFrame([overall_stats]).to_csv(OVERALL_STATS_FILE, index=False)

    print("\nAnalysis Summary:")
    print(f"Total clients analyzed: {overall_stats['total_clients']}")
    print(f"Total requests analyzed: {overall_stats['total_requests']}")
    print(f"Total errors found: {overall_stats['total_errors']}")
    print(f"Average error rate: {overall_stats['avg_error_rate']:.2f}%")

    print("\nOutput Files Generated:")
    print(f"1. {CLIENT_STATS_FILE} - Per-client statistics")
    print(f"2. {OVERALL_STATS_FILE} - Overall statistics")
    if not error_details.empty:
        print(f"3. {ERROR_DETAILS_FILE} - Detailed error information")

# Usage
if __name__ == "__main__":
    client_stats, overall_stats, error_details = analyze_rate_limiting(
        FILE_PATH,
        rate_limit=RATE_LIMIT,
        window_size=WINDOW_SIZE
    )

    save_and_print_results(client_stats, overall_stats, error_details)