import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import os

# Define file paths
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "../../cloud/logs/2025_02_28_05_12"))
FILE_PATH = os.path.join(ROOT_DIR, "test_result_summary.csv")

df = pd.read_csv(FILE_PATH)

# Clean up the DataFrame
df = df.rename(columns=lambda x: x.strip())  # Remove leading/trailing whitespace

# Filter for Redis and both async and script versions
script_df = df[(df['Database'] == 'redis') & (df['Version'].isin(['async', 'script']))].copy()

# Mapping of algorithms to specific configurations (batch_percent = 0.5 for async)
config_mapping = {
    'fixed_window_counter': {
        'async': 'rate_limit_100_window_size_60_batch_percent_0.5',
        'script': 'rate_limit_100_window_size_60'
    },
    'sliding_window_logs': {
        'async': 'rate_limit_100_window_size_60_batch_percent_0.5',
        'script': 'rate_limit_100_window_size_60'
    },
    'sliding_window_counter': {
        'async': 'rate_limit_100_window_size_60_sub_window_count_5_batch_percent_0.5',
        'script': 'rate_limit_100_window_size_60_sub_window_count_5'
    },
    'token_bucket': {
        'async': 'bucket_capacity_5_refill_rate_1.67_batch_percent_0.5',
        'script': 'bucket_capacity_5_refill_rate_1.67'
    }
}

# Filter the DataFrame based on the mapping
filtered_rows = []
for algorithm, configs in config_mapping.items():
    for version, config in configs.items():
        filtered_rows.append(script_df[(script_df['Algorithm'] == algorithm) & (script_df['Version'] == version) & (script_df['Config'] == config)])

script_df = pd.concat(filtered_rows)

# Determine the no throttling latency value
no_throttling_latency = df[df['Algorithm'] == 'base']['Average Latency (ms)'].mean()

# Function to create and save plots
def create_bar_plot(y_col, title, ylabel, output_filename, file_format='eps'):
    plt.figure(figsize=(12, 6))  # Adjust figure size as needed
    
    # Set font properties
    plt.rcParams.update({
        'font.size': 12,
        'font.family': 'sans-serif',
        'font.serif': ['Arial'],
        'font.weight': 560
    })

    if y_col == 'Average Latency (ms)':
        plt.ylim(250, 280)

    bar_plot = sns.barplot(x='Algorithm', y=y_col, hue='Version', data=script_df)
    # plt.title(title)
    plt.xlabel('Algorithm', labelpad=15, fontsize=14, weight='bold')
    plt.ylabel(ylabel, labelpad=15, fontsize=14, weight='bold')
    plt.tight_layout()


    # Annotate each bar with the value
    for p in bar_plot.patches:
        if p.get_height() == 0:
            continue
        bar_plot.annotate(format(p.get_height(), '.2f'),
                          (p.get_x() + p.get_width() / 2., p.get_height()),
                          ha='center', va='center',
                          xytext=(0, 9),
                          textcoords='offset points')

    # Draw a horizontal line for no throttling latency on latency plot
    if y_col == 'Average Latency (ms)':
        plt.axhline(no_throttling_latency, color='red', linestyle='--', 
                    label=f'No Throttling Latency: {no_throttling_latency:.2f} ms')
        plt.legend()

    # Add legend with custom labels
    handles, labels = bar_plot.get_legend_handles_labels()
    new_labels = ['Asynchronous' if label == 'async' else 'Normal' if label == 'script' else label for label in labels]
    if y_col == 'Average Latency (ms)':
        plt.legend(handles, new_labels, loc='upper left')
    else:
        plt.legend(handles, new_labels, loc='upper center')

    # Convert x-axis labels to "Snake Case" and handle special case for GCRA
    def format_label(label):
        if label == 'gcra':
            return 'GCRA'
        if label == 'sliding_window_logs':
            return 'Sliding Window Log'
        return label.replace('_', ' ').title()

    # Set the x-ticks and labels
    bar_plot.set_xticks(range(len(bar_plot.get_xticklabels())))
    bar_plot.set_xticklabels([format_label(label.get_text()) for label in bar_plot.get_xticklabels()])

    # Save the plot
    output_file_path = os.path.join(ROOT_DIR, f"{output_filename}.{file_format}")
    plt.savefig(output_file_path, format=file_format)
    plt.show()

# Generate plots
create_bar_plot('Average Latency (ms)', 'Average Latency Comparison: Asynchronous vs. Normal versions of Algorithms using Redis', 'Average Latency (ms)', "async_script_redis_latency", "eps")
create_bar_plot('Avg Error Rate', 'Throttling Deviation (%) Comparison: Asynchronous vs. Normal versions of Algorithms using Redis', 'Throttling Deviation (%)', "async_script_redis_throttling_deviation", "eps")