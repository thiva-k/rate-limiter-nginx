import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import os

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
FILE_PATH = os.path.join(CURRENT_DIR, "test_result_summary.csv")
df = pd.read_csv(FILE_PATH)

# Clean up the DataFrame
df = df.rename(columns=lambda x: x.strip())  # Remove leading/trailing whitespace

# Filter for script versions
script_df = df[df['Version'] == 'script'].copy()  # Avoid SettingWithCopyWarning

# Filter for algorithms of interest to avoid plot issues
algorithms = ['fixed_window_counter', 'sliding_window_log', 'sliding_window_counter', 'token_bucket', 'leaky_bucket']
script_df = script_df[script_df['Algorithm'].isin(algorithms)]

# Mapping of algorithms to specific configurations
config_mapping = {
    'fixed_window_counter': 'rate_limit = 100, window_size = 60s',
    'sliding_window_log': 'rate_limit = 100, window_size = 60s',
    'sliding_window_counter': 'rate_limit = 100, sub_windows = 5, window_size = 60s',
    'token_bucket': 'refill_rate = 5/3 token/s , bucket_capacity =5',
    'leaky_bucket': 'rate_limit = 100, leak_rate = 5/3 req/s, max_delay = 3000s'
}

# Filter the DataFrame based on the mapping
filtered_rows = []
for algorithm, config in config_mapping.items():
    filtered_rows.append(script_df[(script_df['Algorithm'] == algorithm) & (script_df['Config'] == config)])

script_df = pd.concat(filtered_rows)

# Determine the no throttling latency value
no_throttling_latency = df[df['Algorithm'] == 'none']['Latency (ms)'].mean()

# Create the plot
plt.figure(figsize=(12, 8))  # Adjust figure size as needed
bar_plot = sns.barplot(x='Algorithm', y='Latency (ms)', hue='Database', data=script_df)
plt.title('Latency comparison by algorithm and database')
plt.xlabel('Algorithm')
plt.ylabel('Latency (ms)')
plt.xticks(rotation=45, ha='right')  # Rotate x-axis labels for readability
plt.tight_layout()  # Adjust layout to fit everything nicely

# Annotate each bar with the latency value
for p in bar_plot.patches:
    bar_plot.annotate(format(p.get_height(), '.2f'),
                      (p.get_x() + p.get_width() / 2., p.get_height()),
                      ha = 'center', va = 'center',
                      xytext = (0, 9),  # 9 points vertical offset
                      textcoords = 'offset points')

# Draw a horizontal line for the no throttling latency value
plt.axhline(no_throttling_latency, color='red', linestyle='--', label=f'No Throttling Latency: {no_throttling_latency:.2f} ms')

# Add legend
plt.legend()

# Save the plot to the current directory
output_file_path = os.path.join(CURRENT_DIR, "algorithm_latency_by_database.png")
plt.savefig(output_file_path)

# Show the plot (optional)
plt.show()