import os
import pandas as pd
import subprocess

def run_script(script_path, working_dir):
    try:
        result = subprocess.run(["python", script_path], cwd=working_dir, capture_output=True, text=True)
        print(f"Executed {script_path} in {working_dir}")
        print(result.stdout)
        if result.stderr:
            print(f"Error running {script_path}: {result.stderr}")
    except Exception as e:
        print(f"Failed to execute {script_path}: {e}")

def check_and_run_analyzers(root_dir, error_script, perf_script):
    for algorithm in os.listdir(root_dir):
        algo_path = os.path.join(root_dir, algorithm)
        if not os.path.isdir(algo_path):
            continue

        for subfolder in os.listdir(algo_path):
            subfolder_path = os.path.join(algo_path, subfolder)
            if not os.path.isdir(subfolder_path):
                continue

            error_file = os.path.join(subfolder_path, "overall_error_stats.csv")
            perf_file = os.path.join(subfolder_path, "performance_metrics.csv")

            # Run error rate analyzer if missing
            if not os.path.exists(error_file):
                print(f"Missing {error_file}, running {error_script}...")
                run_script(error_script, subfolder_path)

            # Run performance analyzer if missing
            if not os.path.exists(perf_file):
                print(f"Missing {perf_file}, running {perf_script}...")
                run_script(perf_script, subfolder_path)

def parse_folder_name(folder_name):
    parts = folder_name.split("_")
    if len(parts) < 4:
        return None, None, None  # Ensure we have enough parts
    
    database = parts[0]  # mysql/redis
    version = parts[1]  # script/async
    config = "_".join(parts[2:])  # Remaining as config
    return database, version, config

def process_results(root_dir):
    results = []
    
    for algorithm in os.listdir(root_dir):
        algo_path = os.path.join(root_dir, algorithm)
        if not os.path.isdir(algo_path):
            continue
        
        for subfolder in os.listdir(algo_path):
            subfolder_path = os.path.join(algo_path, subfolder)
            if not os.path.isdir(subfolder_path):
                continue
            
            database, version, config = parse_folder_name(subfolder)
            
            # Load overall_error_stats.csv
            error_file = os.path.join(subfolder_path, "overall_error_stats.csv")
            perf_file = os.path.join(subfolder_path, "performance_metrics.csv")
            
            if not os.path.exists(error_file) or not os.path.exists(perf_file):
                print(f"Stopping processing for algorithm '{algorithm}', subfolder '{subfolder}' as error/performance files are missing.")
                continue
            
            error_df = pd.read_csv(error_file)
            perf_df = pd.read_csv(perf_file)
            
            avg_error_rate = error_df.iloc[0]['avg_error_rate']
            avg_throughput = perf_df.iloc[0]['Average Throughput (req/sec)']
            avg_latency = perf_df.iloc[0]['Average Latency (ms)']
            
            results.append([algorithm, database, version, config, avg_throughput, avg_latency, avg_error_rate])
    
    # Convert results to DataFrame
    columns = ["Algorithm", "Database", "Version", "Config", "Average Throughput (req/sec)", "Average Latency (ms)", "Avg Error Rate"]
    df = pd.DataFrame(results, columns=columns)
    return df

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    logs_directory = os.path.abspath(os.path.join(script_dir, "../cloud/logs/2025_02_27_09_12"))

    # step 1
    error_analyzer_script = "error_rate_analyzer.py"
    perf_analyzer_script = "performance_analyzer.py"

    check_and_run_analyzers(logs_directory, error_analyzer_script, perf_analyzer_script)

    # step 2
    final_df = process_results(logs_directory)
    print(final_df)
    output_file = os.path.join(logs_directory, "test_result_summary.csv")
    final_df.to_csv(output_file, index=False)