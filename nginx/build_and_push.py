import subprocess

# Configuration
GCP_PROJECT_ID = "triple-throttlers-446213"  # Replace with your GCP project ID
REGION = "us-central1"  # Replace with your desired region
REPOSITORY = "nginx"  # Replace with your Artifact Registry repository name
IMAGE_NAME = "nginx"
TAG = "latest"
DOCKERFILE_PATH = "./nginx"  # Path to your Dockerfile and context directory

# Full image name for Artifact Registry
FULL_IMAGE_NAME = f"{REGION}-docker.pkg.dev/{GCP_PROJECT_ID}/{REPOSITORY}/{IMAGE_NAME}:{TAG}"

def run_command(command):
    """Runs a system command and handles errors."""
    try:
        subprocess.check_call(command, shell=True)
        return True
    except subprocess.CalledProcessError as e:
        print(f"An error occurred: {e}")
        return False

def authenticate_gcp():
    """Authenticate with GCP and configure Docker."""
    print("Authenticating with Google Cloud...")
    
    # Configure Docker to use GCP credentials
    auth_command = f"gcloud auth configure-docker {REGION}-docker.pkg.dev"
    if not run_command(auth_command):
        print("Failed to authenticate with GCP")
        exit(1)
    print("Authentication successful")

def build_image():
    """Build the Docker image."""
    print(f"Building Docker image {FULL_IMAGE_NAME}...")
    command = f"docker build -t {FULL_IMAGE_NAME} {DOCKERFILE_PATH}"
    if not run_command(command):
        print("Failed to build image")
        exit(1)
    print("Docker image built successfully.")

def push_image():
    """Push the Docker image to Artifact Registry."""
    print(f"Pushing Docker image {FULL_IMAGE_NAME} to Artifact Registry...")
    command = f"docker push {FULL_IMAGE_NAME}"
    if not run_command(command):
        print("Failed to push image")
        exit(1)
    print("Docker image pushed successfully.")

def main():
    # Authenticate with GCP first
    authenticate_gcp()
    
    # Build and push the image
    build_image()
    push_image()

if __name__ == "__main__":
    main()