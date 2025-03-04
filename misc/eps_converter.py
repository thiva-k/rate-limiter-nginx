import os
import subprocess

# Define the folder containing SVG files
script_dir = os.path.dirname(os.path.abspath(__file__))
root_dir = os.path.abspath(os.path.join(script_dir, "../jmeter/cloud/logs/2025_02_28_05_12"))
output_folder = os.path.join(root_dir, "eps_output")

for file_name in os.listdir(root_dir):
    if file_name.lower().endswith(".svg"):
        svg_path = os.path.join(root_dir, file_name)
        eps_path = os.path.join(output_folder, os.path.splitext(file_name)[0] + ".eps")

        # Run Inkscape command
        command = f'inkscape "{svg_path}" --export-type=eps --export-filename="{eps_path}"'
        subprocess.run(command, shell=True, check=True)
        
        print(f"Converted: {file_name} -> {eps_path}")

print("Conversion completed!")
