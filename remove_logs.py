import os
import shutil

def clear_directory_contents(path):
    for root, dirs, files in os.walk(path):
        # Delete all files
        for file in files:
            file_path = os.path.join(root, file)
            os.remove(file_path)
        
        # Delete all subdirectories
        for dir in dirs:
            dir_path = os.path.join(root, dir)
            shutil.rmtree(dir_path)

def main():
    logs_path = 'logs'
    if os.path.exists(logs_path):
        for folder in os.listdir(logs_path):
            folder_path = os.path.join(logs_path, folder)
            if os.path.isdir(folder_path):
                clear_directory_contents(folder_path)

if __name__ == "__main__":
    main()
