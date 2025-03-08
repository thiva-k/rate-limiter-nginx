import pandas as pd
import matplotlib.pyplot as plt
from datetime import datetime
import os
import numpy as np
import scipy.stats as stats

def compute_confidence_interval(data, confidence=0.95):
    """
    Compute the confidence interval for the mean latency.

    Parameters:
        data (pandas.Series): Data series containing latency values.
        confidence (float): Confidence level (default: 95%)

    Returns:
        tuple: (lower_bound, upper_bound)
    """
    n = len(data)
    mean = data.mean()
    std_err = stats.sem(data)  # Standard error of the mean
    confidence_value = stats.t.ppf((1 + confidence) / 2, df=n-1)  # t-distribution critical value
    
    margin_of_error = confidence_value * std_err
    lower_bound = mean - margin_of_error
    upper_bound = mean + margin_of_error

    return lower_bound, upper_bound

def determine_sample_sufficiency(data, confidence=0.95, desired_moe=5):
    """
    Determine if the current sample size is sufficient based on the margin of error.

    Parameters:
        data (pandas.Series): Data series containing latency values.
        confidence (float): Confidence level (default: 95%)
        desired_moe (float): Desired margin of error (default: 5ms)

    Returns:
        dict: Contains current margin of error and required sample size.
    """
    n = len(data)
    mean_latency = data.mean()
    std_dev = data.std()
    std_err = stats.sem(data)  # Standard error of the mean

    # Compute critical value (t-score for small samples, z-score for large samples)
    critical_value = stats.t.ppf((1 + confidence) / 2, df=n - 1)

    # Calculate the actual margin of error
    actual_moe = critical_value * std_err

    # Calculate required sample size for the desired margin of error
    required_sample_size = (critical_value * std_dev / desired_moe) ** 2
    required_sample_size = int(np.ceil(required_sample_size))  # Round up to the next whole number

    return {
        "actual_margin_of_error": actual_moe,
        "required_sample_size": required_sample_size,
        "current_sample_size": n
    }


def analyze_performance(file_path, time_window=5):
    """
    Analyze JMeter logs for throughput and latency metrics.
    
    Parameters:
        file_path (str): Path to the JMeter results CSV file
        time_window (int): Window size in seconds for calculating throughput
        
    Returns:
        dict: Dictionary containing performance metrics and DataFrame with time series data
    """
    # Read the JMeter results file
    df = pd.read_csv(file_path)
    df.columns = [
        "timeStamp", "elapsed", "label", "responseCode", "responseMessage", "threadName",
        "dataType", "success", "failureMessage", "bytes", "sentBytes", "grpThreads",
        "allThreads", "URL", "Latency", "IdleTime", "Connect"
    ]
    
    # Convert timestamp to datetime
    df['datetime'] = pd.to_datetime(df['timeStamp'], unit='ms')
    
    # Calculate test duration in seconds
    test_duration = (df['timeStamp'].max() - df['timeStamp'].min()) / 1000
    
    # Calculate overall metrics
    total_requests = len(df)
    overall_throughput = total_requests / test_duration  # requests per second
    average_latency = df['Latency'].mean()
    
    # Create time series data for throughput calculation
    # Group requests into time windows
    df['time_window'] = ((df['timeStamp'] - df['timeStamp'].min()) / (time_window * 1000)).astype(int)
    
    # Calculate throughput per window
    throughput_series = df.groupby('time_window').size().reset_index()
    throughput_series.columns = ['time_window', 'requests']
    throughput_series['throughput'] = throughput_series['requests'] / time_window
    throughput_series['time'] = throughput_series['time_window'] * time_window
    
    # Calculate moving average latency
    latency_series = df.sort_values('timeStamp').copy()
    latency_series['rolling_avg_latency'] = df['Latency'].rolling(window=100, min_periods=1).mean()
    
    # Calculate percentiles for latency
    latency_percentiles = {
        'p50': df['Latency'].quantile(0.50),
        'p90': df['Latency'].quantile(0.90),
        'p95': df['Latency'].quantile(0.95),
        'p99': df['Latency'].quantile(0.99)
    }
    
    metrics = {
        'total_requests': total_requests,
        'test_duration_seconds': test_duration,
        'avg_throughput': overall_throughput,
        'avg_latency': average_latency,
        'latency_percentiles': latency_percentiles
    }

        # Compute confidence interval for latency
    ci_lower, ci_upper = compute_confidence_interval(df['Latency'])

    # Update the metrics dictionary
    metrics['latency_confidence_interval'] = (ci_lower, ci_upper)

        # Determine if the sample size is sufficient
    sample_analysis = determine_sample_sufficiency(df['Latency'], confidence=0.95, desired_moe=5)

    # Update metrics dictionary
    metrics['sample_sufficiency'] = sample_analysis


    
    return metrics, throughput_series, latency_series

def plot_performance_graphs(throughput_series, latency_series, output_dir):
    """Create and save performance visualization graphs."""
    # Create throughput graph
    plt.figure(figsize=(12, 6))
    plt.plot(throughput_series['time'], throughput_series['throughput'])
    plt.title('Throughput Over Time')
    plt.xlabel('Time (seconds)')
    plt.ylabel('Requests per Second')
    plt.grid(True)
    plt.savefig(os.path.join(output_dir, 'throughput.png'))
    plt.close()
    
    # Create latency graph
    plt.figure(figsize=(12, 6))
    plt.plot(latency_series['datetime'], latency_series['rolling_avg_latency'])
    plt.title('Average Latency Over Time (100 Request Rolling Window)')
    plt.xlabel('Time')
    plt.ylabel('Latency (ms)')
    plt.grid(True)
    plt.xticks(rotation=45)
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'latency.png'))
    plt.close()

def save_metrics(metrics, output_dir):
    """Save metrics to a CSV file."""
    # Flatten metrics dictionary for CSV
    flat_metrics = {
        'Total Requests': metrics['total_requests'],
        'Test Duration (seconds)': metrics['test_duration_seconds'],
        'Average Throughput (req/sec)': metrics['avg_throughput'],
        'Average Latency (ms)': metrics['avg_latency'],
        'Latency P50 (ms)': metrics['latency_percentiles']['p50'],
        'Latency P90 (ms)': metrics['latency_percentiles']['p90'],
        'Latency P95 (ms)': metrics['latency_percentiles']['p95'],
        'Latency P99 (ms)': metrics['latency_percentiles']['p99']
    }
    
    pd.DataFrame([flat_metrics]).to_csv(
        os.path.join(output_dir, 'performance_metrics.csv'),
        index=False
    )

def print_metrics(metrics):
    """Print performance metrics in a readable format."""
    print("\nPerformance Analysis Results:")
    print("-" * 40)
    print(f"Total Requests: {metrics['total_requests']:,}")
    print(f"Test Duration: {metrics['test_duration_seconds']:.2f} seconds")
    print(f"Average Throughput: {metrics['avg_throughput']:.2f} requests/second")
    print(f"Average Latency: {metrics['avg_latency']:.2f} ms")
    print("\nLatency Percentiles:")
    print(f"50th percentile: {metrics['latency_percentiles']['p50']:.2f} ms")
    print(f"90th percentile: {metrics['latency_percentiles']['p90']:.2f} ms")
    print(f"95th percentile: {metrics['latency_percentiles']['p95']:.2f} ms")
    print(f"99th percentile: {metrics['latency_percentiles']['p99']:.2f} ms")
    print(f"95% Confidence Interval for Mean Latency: ({metrics['latency_confidence_interval'][0]:.2f}, {metrics['latency_confidence_interval'][1]:.2f}) ms")
    print("\nSample Size Analysis:")
    print(f"Current Sample Size: {metrics['sample_sufficiency']['current_sample_size']}")
    print(f"Actual Margin of Error: {metrics['sample_sufficiency']['actual_margin_of_error']:.2f} ms")
    print(f"Required Sample Size for Desired MoE: {metrics['sample_sufficiency']['required_sample_size']}")


if __name__ == "__main__":
    # Set up paths
    current_dir = os.path.dirname(os.path.abspath(__file__))
    input_file = os.path.join(current_dir, "jmeter_results.csv")
    
    # Create output directory
    output_dir = current_dir
    os.makedirs(output_dir, exist_ok=True)
    
    # Check if input file exists
    if not os.path.exists(input_file):
        print(f"Error: Input file 'jmeter_results.csv' not found in the current directory.")
        exit(1)
    
    # Analyze performance
    metrics, throughput_series, latency_series = analyze_performance(
        input_file,
        time_window=5  # 5-second windows for throughput calculation
    )
    
    # Generate outputs
    plot_performance_graphs(throughput_series, latency_series, output_dir)
    save_metrics(metrics, output_dir)
    print_metrics(metrics)
    
    print("\nOutput files generated:")
    print(f"1. {os.path.join(output_dir, 'performance_metrics.csv')}")
    print(f"2. {os.path.join(output_dir, 'throughput.png')}")
    print(f"3. {os.path.join(output_dir, 'latency.png')}")