import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import os

# Define file paths
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
FILE_PATH = os.path.join(CURRENT_DIR, "test_result_summary.csv")

df = pd.read_csv(FILE_PATH)

# Clean up the DataFrame
df = df.rename(columns=lambda x: x.strip())  # Remove leading/trailing whitespace

# Filter for script versions
script_df = df[df['Version'] == 'script'].copy()  # Avoid SettingWithCopyWarning

# Filter for algorithms of interest
algorithms = ['fixed_window_counter', 'sliding_window_log', 'sliding_window_counter', 'token_bucket', 'leaky_bucket']
script_df = script_df[script_df['Algorithm'].isin(algorithms)]

# Mapping of algorithms to specific configurations
config_mapping = {
    'fixed_window_counter': 'rate_limit = 100, window_size = 60s',
    'sliding_window_log': 'rate_limit = 100, window_size = 60s',
    'sliding_window_counter': 'rate_limit = 100, sub_windows = 5, window_size = 60s',
    'token_bucket': 'refill_rate = 5/3 token/s , bucket_capacity = 5',
    'leaky_bucket': 'rate_limit = 100, leak_rate = 5/3 req/s, max_delay = 3s'
}

# Filter the DataFrame based on the mapping
filtered_rows = [script_df[(script_df['Algorithm'] == algo) & (script_df['Config'] == config)] for algo, config in config_mapping.items()]
script_df = pd.concat(filtered_rows)

# Determine the no throttling latency value
no_throttling_latency = df[df['Algorithm'] == 'none']['Latency (ms)'].mean()

# Function to create and save plots
def create_bar_plot(y_col, title, ylabel, output_filename):
    plt.figure(figsize=(12, 8))  # Adjust figure size as needed
    bar_plot = sns.barplot(x='Algorithm', y=y_col, hue='Database', data=script_df)
    plt.title(title)
    plt.xlabel('Algorithm')
    plt.ylabel(ylabel)
    plt.xticks(rotation=45, ha='right')
    plt.tight_layout()

    # Annotate each bar with the value
    for p in bar_plot.patches:
        bar_plot.annotate(format(p.get_height(), '.2f'),
                          (p.get_x() + p.get_width() / 2., p.get_height()),
                          ha='center', va='center',
                          xytext=(0, 9),
                          textcoords='offset points')

    # Draw a horizontal line for no throttling latency on latency plot
    if y_col == 'Latency (ms)':
        plt.axhline(no_throttling_latency, color='red', linestyle='--', 
                    label=f'No Throttling Latency: {no_throttling_latency:.2f} ms')
        plt.legend()

    # Save the plot
    output_file_path = os.path.join(CURRENT_DIR, output_filename)
    plt.savefig(output_file_path)
    plt.show()

# Generate both plots
create_bar_plot('Latency (ms)', 'Latency comparison by algorithm (script) and database', 'Latency (ms)', "algorithm_latency_by_database.png")
create_bar_plot('Throttling Deviation (%)', 'Throttling Deviation (%) comparison by algorithm (script) and database', 'Throttling Deviation (%)', "algorithm_throttling_deviation_by_database.png")
