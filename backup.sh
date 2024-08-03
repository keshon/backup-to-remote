#!/bin/bash

# Description:
# This script performs backups of specified application directories, uploads the backups to a remote location using rclone,
# and cleans up old backups both locally and remotely. It checks for changes in the directories and creates backups only if changes are found.

# Load environment variables from .env file
source .env

# Function to check for changes based on modification date and create a backup if changes are found
backup_if_changed() {
    local app_path=$1
    local app_name=$(basename "$app_path")
    local last_backup_file="${LOCAL_BACKUP_PATH}/${app_name}_last_backup.txt"
    local current_backup_file="${LOCAL_BACKUP_PATH}/${app_name}_current.txt"

    # Create backup directory if it doesn't exist
    mkdir -p "$LOCAL_BACKUP_PATH"

    # Generate list of files with their modification dates
    find "$app_path" -type f -exec stat --format '%Y %n' {} \; | sort -k 2 > "$current_backup_file"

    # Check if the last backup file exists
    if [ ! -f "$last_backup_file" ]; then
        # No previous backup found, create a new backup
        echo "No previous backup found for $app_path. Creating initial backup."
        local archive_file="${LOCAL_BACKUP_PATH}/${app_name}_$(date +%Y%m%d%H%M%S).zip"
        zip -r "$archive_file" "$app_path"
        mv "$current_backup_file" "$last_backup_file"
        # Call upload script
        "$UPLOAD_SCRIPT" "$archive_file"
        # Call cleaning script
        "$CLEANING_SCRIPT" "$LOCAL_BACKUP_PATH"
    else
        # Compare the current state with the last backup
        if ! diff "$last_backup_file" "$current_backup_file" > /dev/null; then
            # Changes detected, create a new backup
            echo " "
            echo "Changes detected in $app_path. Creating backup."
            local archive_file="${LOCAL_BACKUP_PATH}/${app_name}_$(date +%Y%m%d%H%M%S).zip"
            zip -r "$archive_file" "$app_path"
            mv "$current_backup_file" "$last_backup_file"
            # Call upload script
            "$UPLOAD_SCRIPT" "$archive_file"
            # Call cleaning script
            "$CLEANING_SCRIPT" "$LOCAL_BACKUP_PATH"
        else
            # No changes detected
            echo "No changes detected in $app_path."
            rm "$current_backup_file"
        fi
    fi
}

# Read the list file and process each path
while IFS= read -r app_path; do
    if [ -d "$app_path" ]; then
        backup_if_changed "$app_path"
    else
        echo "Directory $app_path does not exist."
    fi
done < "$LIST_FILE"

# Call the stats script to publish statistics
"$STATS_SCRIPT"