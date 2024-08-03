#!/bin/bash

# Description:
# This script cleans up old backup files both locally and remotely.
# It retains a specified number of the most recent backup files on the remote server and deletes the rest.
# It also removes all .zip files in the local backup directory.

# Load environment variables from .env file
source .env

# Export the rclone config path to use in the script
export RCLONE_CONFIG=${RCLONE_CONFIG_PATH}

# List all files in the remote path
files=$(rclone ls ${RCLONE_CONFIG_NAME}:${REMOTE_PATH})

# Temporary file to store sorted file names
temp_file=$(mktemp)

# Extract base names and sort them by timestamp
echo "$files" | awk '{print $2}' | sort -t_ -k1,1 -k2r,2 > "$temp_file"

# Iterate over the sorted file list
previous_base_name=""
file_count=0
declare -a files_to_delete

while IFS= read -r file; do
  # Extract base name (excluding the timestamp and extension)
  base_name=$(echo "$file" | sed 's/_[0-9]\{14\}\.zip$//')

  if [[ "$base_name" == "$previous_base_name" ]]; then
    ((file_count++))
    if ((file_count > COPIES_TO_KEEP)); then
      files_to_delete+=("$file")
    fi
  else
    previous_base_name="$base_name"
    file_count=1
  fi
done < "$temp_file"

# Remove oldest files from remote to keep only the last COPIES_TO_KEEP
for file in "${files_to_delete[@]}"; do
  echo "Deleting $file from remote"
  rclone delete "${RCLONE_CONFIG_NAME}:${REMOTE_PATH}/$file"
done

# Check and remove zip files in the local backup path
echo "Checking and removing old zip files from local backup path"
find "$LOCAL_BACKUP_PATH" -type f -name "*.zip" -exec rm -v {} +

# Cleanup temporary file
rm "$temp_file"

echo "Cleanup complete."