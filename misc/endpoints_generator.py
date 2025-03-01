import os
import re

# Define the deploy folder path
script_dir = os.path.dirname(os.path.abspath(__file__))
deploy_folder = os.path.abspath(os.path.join(script_dir, "./"))

# Function to extract parameters from filename
def extract_parameters(filename):
    # Remove the file extension and split the filename by underscores
    parts = filename.replace(".lua", "").split("_")
    
    # Extract database and version from the first two parts
    database, version = parts[0], parts[1]
    
    # Initialize an empty dictionary for parameters
    parameters = {}

    # List of possible keys to search for in the filename
    possible_keys = ['rate_limit', 'bucket_capacity', 'refill_rate', 'async_rate', 'window_size', 
                     'batch_percent', 'sub_window_count', 'burst']
    
    # Iterate over possible keys
    for key in possible_keys:
        # Create a pattern to find the key and its value
        pattern = f"{key}_(\d+(\.\d+)?)"
        
        # Search for the key and its value in the filename
        match = re.search(pattern, filename)
        if match:
            parameters[key] = match.group(1)  # Extract the value as a string

    # Return the final extracted parameters dictionary
    return database, version, parameters

# Function to validate parameters in script
def validate_script(filepath, parameters):
    with open(filepath, "r", encoding="utf-8") as file:
        content = file.read()
        for key, value in parameters.items():
            if not re.search(rf"{key}\s*=\s*{value.replace('.', '\.')}", content):  # Escape dots only for regex matching
                print(f"Mismatch in {filepath}: Expected {key} = {value} not found")

# Construct versions dynamically
algorithms = {}
for root, _, files in os.walk(deploy_folder):
    algorithm_name = os.path.basename(root).replace("_", " ").title()
    if algorithm_name not in algorithms:
        algorithms[algorithm_name] = []
    
    for file in files:
        if file.endswith(".lua"):
            relative_path = os.path.relpath(root, deploy_folder)
            version_name = os.path.join(relative_path, file).replace("\\", "/").replace(".lua", "")
            algorithms[algorithm_name].append(f"/{version_name}")
            
            # Extract parameters and validate script
            filepath = os.path.join(root, file)
            _, _, params = extract_parameters(file)
            validate_script(filepath, params)

services = [
    "tools.descartes.teastore.auth/rest",
    "tools.descartes.teastore.recommender/rest",
    "tools.descartes.teastore.persistence/rest",
    "tools.descartes.teastore.image/rest"
]

nginx_template = """
        location {key}/{service} {{
            rewrite ^{key}(/.*)$ $1 break;
            access_by_lua_file lua_scripts{key}.lua;
            proxy_pass http://{service_name};
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }}
"""

output_filename = os.path.join(deploy_folder, "locations.conf")

# Ensure the file exists before writing
if not os.path.exists(output_filename):
    open(output_filename, "w").close()

with open(output_filename, "w") as conf_file:
    for algorithm, versions in algorithms.items():
        conf_file.write(f"\n# {algorithm} Endpoints\n")  # Add comment as heading for each algorithm
        for version in versions:
            conf_file.write(f"\n# # {version.split('/')[-1]}\n")  # Add comment with version name
            for service in services:
                service_name = service.split(".")[-1].split("/")[0]  # Correct extraction of service name
                conf_file.write(nginx_template.format(key=version, service=service, service_name=service_name))

print(f"Nginx configuration written to {output_filename}")