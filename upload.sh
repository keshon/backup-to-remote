#!/bin/bash

# Description:
# This script uploads a specified archive file to a remote location using rclone,
# verifies the upload by checking the existence of the file on the remote, and deletes the local archive if the upload is verified.

# Load environment variables from .env file
source .env

# Arguments
ARCHIVE_PATH=$1

# Ensure the archive path is provided
if [ -z "$ARCHIVE_PATH" ]; then
    echo "Usage: $0 <path-to-archive>"
    exit 1
fi

# Extract the base name of the archive (without path)
ARCHIVE_NAME=$(basename "$ARCHIVE_PATH")

# Upload the archive using rclone
echo "Uploading $ARCHIVE_PATH to $RCLONE_CONFIG_NAME:$REMOTE_PATH"
rclone --config "$RCLONE_CONFIG_PATH" copy "$ARCHIVE_PATH" "$RCLONE_CONFIG_NAME:$REMOTE_PATH" --progress --drive-chunk-size=512M --drive-pacer-burst=195 --drive-pacer-min-sleep=20000ms

# Verify upload by checking the existence of the file on the remote
echo "Verifying upload of $ARCHIVE_PATH"
if rclone --config "$RCLONE_CONFIG_PATH" ls "$RCLONE_CONFIG_NAME:$REMOTE_PATH" | grep -q "$ARCHIVE_NAME"; then
    echo "Upload verified. Deleting local archive."
    rm "$ARCHIVE_PATH"
else
    echo "Upload verification failed. Local archive not deleted."
    exit 1
fi

echo "Uploading operations completed."
