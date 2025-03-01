import os

def rename_file(root_dir):
    for dirpath, _, filenames in os.walk(root_dir):
        if "perfomance_analyzer.py" in filenames:
            old_path = os.path.join(dirpath, "perfomance_analyzer.py")
            new_path = os.path.join(dirpath, "performance_analyzer.py")
            os.rename(old_path, new_path)
            print(f"Renamed: {old_path} -> {new_path}")

if __name__ == "__main__":
    root_directory = "D:/Semester 7/CS4203 - Research and Development Project/Artifacts/rate-limiter-nginx/jmeter/cloud/logs/2025_02_27_09_12"
    rename_file(root_directory)
