import os

def delete_files(root_dir, files_to_delete):
    for dirpath, _, filenames in os.walk(root_dir):
        for file_name in files_to_delete:
            if file_name in filenames:
                file_path = os.path.join(dirpath, file_name)
                os.remove(file_path)
                print(f"Deleted: {file_path}")

if __name__ == "__main__":
    root_directory = "D:/Semester 7/CS4203 - Research and Development Project/Artifacts/rate-limiter-nginx-artifacts/jmeter/cloud/logs/2025_02_28_05_12"
    # files_to_delete = ["perfomance_analyzer.py", "client_error_stats.csv", "error_rate_analyzer.py", "error_request_details.csv", "latency.png", " overall_error_stats.csv", "run_generate_report.bat", "throughput.png"]
    files_to_delete = ["performance_analyzer.py", "client_error_stats.csv", "error_rate_analyzer.py", "error_request_details.csv", "latency.png", "run_generate_report.bat", "throughput.png"]
    delete_files(root_directory, files_to_delete)
