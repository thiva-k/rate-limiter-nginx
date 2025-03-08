import os
import subprocess
from datetime import datetime

# Get the current directory of the script
current_dir = os.path.dirname(os.path.abspath(__file__))

# Set JMeter parameters
LB_1_HOSTNAME = "104.155.182.254"
LB_2_HOSTNAME = "35.246.73.6"
LB_1_PORT = 8090
LB_2_PORT = 8091

WARM_UP_USERS = 20
WARM_UP_TIME = 60
TEST_RUN_TIME = 600
RAMP_UP = 10

GROUP_1 = 75
GROUP_2 = 20
GROUP_3 = 5
GROUP_3_FOR_LEAKY_BUCKET = 6
GROUP_1_REQUEST_RATE = 30
GROUP_2_REQUEST_RATE = 90
GROUP_3_REQUEST_RATE = 120

# Define array of algorithms
algorithms = [
    # no throttling
    "/base/base",

    # fixed_window_counter
    "fixed_window_counter/redis_script_rate_limit_100_window_size_60",
    "fixed_window_counter/redis_async_rate_limit_100_window_size_60_batch_percent_0.5",
    "fixed_window_counter/mysql_script_rate_limit_100_window_size_60",

    # GCRA
    "gcra/mysql_script_period_60_rate_100_burst_5",
    "gcra/redis_script_period_60_rate_100_burst_5",

    # Leaky Bucket
    "leaky_bucket/redis_script_delay_3000_leak_rate_1.67",
    "leaky_bucket/mysql_script_delay_3000_leak_rate_1.67",

    # sliding_window_counter
    "sliding_window_counter/redis_script_rate_limit_100_window_size_60_sub_window_count_5",
    "sliding_window_counter/redis_async_rate_limit_100_window_size_60_sub_window_count_5_batch_percent_0.5",
    "sliding_window_counter/mysql_script_rate_limit_100_window_size_60_sub_window_count_5",
    "sliding_window_counter/redis_script_rate_limit_100_window_size_60_sub_window_count_2",

    # sliding_window_logs
    "sliding_window_logs/redis_script_rate_limit_100_window_size_60",
    "sliding_window_logs/redis_async_rate_limit_100_window_size_60_batch_percent_0.5",
    "sliding_window_logs/mysql_script_rate_limit_100_window_size_60",
    "sliding_window_logs/redis_async_rate_limit_100_window_size_60_batch_percent_0.2",
    "sliding_window_logs/redis_async_rate_limit_100_window_size_60_batch_percent_0.8",

    # token_bucket
    "token_bucket/redis_script_bucket_capacity_5_refill_rate_1.67",
    "token_bucket/redis_async_bucket_capacity_5_refill_rate_1.67_batch_percent_0.5",
    "token_bucket/mysql_script_bucket_capacity_5_refill_rate_1.67",
    "token_bucket/redis_async_bucket_capacity_100_refill_rate_1.67_batch_percent_0.5",
    "token_bucket/redis_async_bucket_capacity_5_refill_rate_1.67_batch_percent_0.2",
    "token_bucket/redis_async_bucket_capacity_5_refill_rate_1.67_batch_percent_0.8",
    "token_bucket/redis_async_bucket_capacity_100_refill_rate_1.67_batch_percent_0.2",
    "token_bucket/redis_async_bucket_capacity_100_refill_rate_1.67_batch_percent_0.8",
]

# Define scripts paths relative to the current directory
scripts = [
    "run_generate_report.bat",
    "../result_analyzers/error_rate_analyzer.py",
    "../result_analyzers/performance_analyzer.py"
]

JMETER_HOME = os.getenv("JMETER_HOME", "C:\\apache-jmeter")  # Adjust as needed

# Get current date and time for log folder naming
timestamp = datetime.now().strftime("%Y_%m_%d_%H_%M")

for algo in algorithms:
    algo_type, algo_version = algo.split("/", 1)
    
    # Determine the correct JMeter test plan
    if algo_type == "leaky_bucket":
        TEST_PLAN = os.path.join(current_dir, "teastore_performance_leaky_bucket.jmx")
        GROUP_3 = GROUP_3_FOR_LEAKY_BUCKET 
    else:
        TEST_PLAN = os.path.join(current_dir, "teastore_performance.jmx")

    # Create log directory with date and time
    log_dir = os.path.join(current_dir, "logs", f"{timestamp}", algo_type, algo_version)
    result_file = os.path.join(log_dir, "jmeter_results.csv")
    jmeter_log = os.path.join(log_dir, "jmeter.log")
    log_file = os.path.join(log_dir, "warm_up_results.csv")

    # Set the new environment variables dynamically with slashes
    auth = f"/{algo_type}/{algo_version}/tools.descartes.teastore.auth/rest"
    persistence = f"/{algo_type}/{algo_version}/tools.descartes.teastore.persistence/rest"
    recommender = f"/{algo_type}/{algo_version}/tools.descartes.teastore.recommender/rest"
    image = f"/{algo_type}/{algo_version}/tools.descartes.teastore.image/rest"

    print(f"Running test for algorithm: {algo_type} version: {algo_version}")
    print(f"Log file: {log_file}")

    # Create log directory if it doesn't exist
    os.makedirs(log_dir, exist_ok=True)

    # Create new file warm_up_results.csv under LOG_DIR folder
    with open(log_file, "w") as f:
        f.write("")

    # Copy necessary scripts to the log directory (use absolute paths from current directory)
    for script in scripts:
        src_path = os.path.join(current_dir, script)  # Calculate full path
        dest_path = os.path.join(log_dir, os.path.basename(script))
        try:
            with open(src_path, "rb") as src, open(dest_path, "wb") as dst:
                dst.write(src.read())
        except FileNotFoundError:
            print(f"Warning: {script} not found, skipping copy.")

    # Save all JMeter properties to a file
    properties = {
        "lb_1_hostname": LB_1_HOSTNAME,
        "lb_2_hostname": LB_2_HOSTNAME,
        "lb_1_port": LB_1_PORT,
        "lb_2_port": LB_2_PORT,
        "warm_up_users": WARM_UP_USERS,
        "warm_up_time": WARM_UP_TIME,
        "test_run_time": TEST_RUN_TIME,
        "ramp_up": RAMP_UP,
        "group_1": GROUP_1,
        "group_2": GROUP_2,
        "group_3": GROUP_3,
        "group_1_request_rate": GROUP_1_REQUEST_RATE,
        "group_2_request_rate": GROUP_2_REQUEST_RATE,
        "group_3_request_rate": GROUP_3_REQUEST_RATE,
        "algorithm": f"{algo_type} version: {algo_version}",
        "auth": auth,
        "persistence": persistence,
        "recommender": recommender,
        "image": image
    }

    properties_file = os.path.join(log_dir, "jmeter.properties")
    with open(properties_file, "w") as f:
        for key, value in properties.items():
            f.write(f"{key}={value}\n")

    # Run JMeter test
    jmeter_cmd = [
        os.path.join(JMETER_HOME, "bin", "jmeter.bat"),
        "-n", "-t", TEST_PLAN,
        "-l", result_file,
        "-j", jmeter_log,
        "-Jlb_1_hostname", LB_1_HOSTNAME,
        "-Jlb_2_hostname", LB_2_HOSTNAME,
        "-Jlb_1_port", str(LB_1_PORT),
        "-Jlb_2_port", str(LB_2_PORT),
        "-Jwarm_up_users", str(WARM_UP_USERS),
        "-Jwarm_up_time", str(WARM_UP_TIME),
        "-Jtest_run_time", str(TEST_RUN_TIME),
        "-Jramp_up", str(RAMP_UP),
        "-Jgroup_1", str(GROUP_1),
        "-Jgroup_2", str(GROUP_2),
        "-Jgroup_3", str(GROUP_3),
        "-Jgroup_1_request_rate", str(GROUP_1_REQUEST_RATE),
        "-Jgroup_2_request_rate", str(GROUP_2_REQUEST_RATE),
        "-Jgroup_3_request_rate", str(GROUP_3_REQUEST_RATE),
        "-Jlog_file", log_file,
        "-Jalgorithm", f"{algo_type}_{algo_version}",
        "-Jauth", auth,
        "-Jpersistence", persistence,
        "-Jrecommender", recommender,
        "-Jimage", image
    ]

    subprocess.run(jmeter_cmd, shell=True)
