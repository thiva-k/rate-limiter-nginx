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

# Filter for script versions
script_df = df[df['Version'] == 'script'].copy()  # Avoid SettingWithCopyWarning

# Filter for algorithms of interest
algorithms = ['fixed_window_counter', 'sliding_window_logs', 'sliding_window_counter', 'token_bucket', 'gcra']
script_df = script_df[script_df['Algorithm'].isin(algorithms)]

# Mapping of algorithms to specific configurations
config_mapping = {
    'fixed_window_counter': 'rate_limit_100_window_size_60',
    'sliding_window_logs': 'rate_limit_100_window_size_60',
    'sliding_window_counter': 'rate_limit_100_window_size_60_sub_window_count_5',
    'token_bucket': 'bucket_capacity_5_refill_rate_1.67',
    'gcra': 'period_60_rate_100_burst_5'
}

# Filter the DataFrame based on the mapping
filtered_rows = [script_df[(script_df['Algorithm'] == algo) & (script_df['Config'] == config)] for algo, config in config_mapping.items()]
script_df = pd.concat(filtered_rows)
print(script_df)
# Determine the no throttling latency value
no_throttling_latency = df[df['Algorithm'] == 'base']['Average Latency (ms)'].mean()

# Function to create and save plots
def create_bar_plot(y_col, title, ylabel, output_filename, file_format='eps'):
    plt.figure(figsize=(13, 6))  # Adjust figure size as needed

    plt.rcParams.update({
        'font.size': 13,
        'font.family': 'sans-serif',
        'font.serif': ['Arial']
    })

    if y_col == 'Average Latency (ms)':
        plt.ylim(250, 280)
    else:
        plt.ylim(0, 2.5)
    bar_plot = sns.barplot(x='Algorithm', y=y_col, hue='Database', data=script_df)
    # plt.title(title)
    plt.xlabel('Algorithm')
    plt.ylabel(ylabel)
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

    # Add legend with custom labels and title
    handles, labels = bar_plot.get_legend_handles_labels()
    new_labels = ['Redis' if label == 'redis' else 'MySQL' if label == 'mysql' else 'CRDT' if label == 'crdt' else label for label in labels]
    plt.legend(handles, new_labels, title='Data Stores', loc='lower right')

    # Convert x-axis labels to "Snake Case" and handle special case for GCRA
    def format_label(label):
        if label == 'gcra':
            return 'GCRA'
        return label.replace('_', ' ').title()
    
    # Set the x-ticks and labels
    bar_plot.set_xticks(range(len(bar_plot.get_xticklabels())))
    bar_plot.set_xticklabels([format_label(label.get_text()) for label in bar_plot.get_xticklabels()])

    # Save the plot
    output_file_path = os.path.join(ROOT_DIR, f"{output_filename}.{file_format}")
    plt.savefig(output_file_path, format=file_format)
    plt.show()

# Generate both plots
create_bar_plot('Average Latency (ms)', 'Average Latency Comparison by Algorithms and Data Stores', 'Latency (ms)', "algorithm_latency_by_database", "eps")
create_bar_plot('Avg Error Rate', 'Throttling Deviation (%) Comparison by Algorithms and Data Stores', 'Throttling Deviation (%)', "algorithm_throttling_deviation_by_database", "eps")