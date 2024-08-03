# 🎯 Backup-to-Remote Scripts (Rclone powered)

This suite of scripts is designed to manage backups of application directories, upload them to a remote server, clean up old backups, and publish statistics on storage usage. Below is a brief overview of each component and its purpose.

## 📁 Scripts Overview

### 1. **`backup.sh`** 
Performs backups of specified application directories:
- Checks for changes in the directories.
- Creates a backup only if changes are detected.
- Uploads the backup to remote storage.
- Cleans up old backups locally and remotely.
- **Usage**: `./backup.sh`

### 2. **`upload.sh`**
Uploads a specified archive file to a remote location using rclone:
- Verifies the upload by checking the existence of the file on the remote.
- Deletes the local archive if the upload is verified.
- **Usage**: `./upload.sh <path-to-archive>`

### 3. **`cleanup.sh`**
Cleans up old backup files both locally and remotely:
- Retains a specified number of the most recent backup files on the remote server.
- Removes old `.zip` files from the local backup directory.
- **Usage**: `./cleanup.sh`

### 4. **`stats.sh`**
Generates and displays storage statistics for the remote backup folder:
- Lists all files and their sizes.
- Shows total occupied space and remaining space.
- **Usage**: `./stats.sh [remote-path]`

## 🔧 Dependencies

Ensure you have the following installed:
- `rclone` for managing remote storage.
- `zip` for creating backups.
- `find` and `stat` for file modification checks.
- `diff` for comparing file states.

## 🌟 Configuration

Configuration settings are managed through the `.env` file. Here’s a summary:

- **`LIST_FILE`**: Path to the file containing application directories for backup.
- **`LOCAL_BACKUP_PATH`**: Local directory for temporary backups.
- **`UPLOAD_SCRIPT`**: Path to the upload script.
- **`CLEANING_SCRIPT`**: Path to the cleaning script.
- **`STATS_SCRIPT`**: Path to the statistics script.
- **`COPIES_TO_KEEP`**: Number of backup copies to retain on remote storage.
- **`RCLONE_CONFIG_PATH`**: Path to the rclone configuration file.
- **`RCLONE_CONFIG_NAME`**: Name of the rclone remote configuration`*`.
- **`REMOTE_PATH`**: Remote path in the rclone configuration.

`*` Configure rclone remote configuration file using:
```bash
rclone config --config ./rclone.conf
```
Follow the prompts to configure your remote storage and save the configuration

## 📦 Installation

### 1. Clone this repository:
```bash
git clone <repository-url>
cd <repository-directory>
```

### 2. Create and configure your .env file:
```bash
cp .env.example .env
```
Edit .env to set your configuration values (see `🌟 Configuration` section above)

### 3. Make sure all scripts are executable:
```bash
chmod +x backup.sh upload.sh cleanup.sh stats.sh
```

## 🚀 Running the Scripts
Main script:
- Backup: ./backup.sh

Additional scripts (used by `backup.sh` or independently of it)
- Upload: ./upload.sh <path-to-archive>
- Cleanup: ./cleanup.sh
- Statistics: ./stats.sh [remote-path]

For more detailed information on each script, refer to the comments within the scripts themselves.