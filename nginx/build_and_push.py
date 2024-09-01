import os
import subprocess

# Configuration
namespace = "thivaharan"
image_name = "nginx"
tag = "latest"
dockerfile_path = "./nginx"  # Path to your Dockerfile and context directory

# Full image name
full_image_name = f"{namespace}/{image_name}:{tag}"

def run_command(command):
    """Runs a system command and handles errors."""
    try:
        subprocess.check_call(command, shell=True)
    except subprocess.CalledProcessError as e:
        print(f"An error occurred: {e}")
        exit(1)

def build_image():
    """Build the Docker image."""
    print(f"Building Docker image {full_image_name}...")
    command = f"docker build -t {full_image_name} {dockerfile_path}"
    run_command(command)
    print("Docker image built successfully.")

def push_image():
    """Push the Docker image to Docker Hub."""
    print(f"Pushing Docker image {full_image_name} to Docker Hub...")
    command = f"docker push {full_image_name}"
    run_command(command)
    print("Docker image pushed successfully.")

def main():
    build_image()
    push_image()

if __name__ == "__main__":
    main()
