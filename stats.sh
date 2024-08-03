#!/bin/bash

# Description:
# This script shows statistics of the specified rclone folder, including
# a list of files and their sizes, total occupied space, and remaining space if available.

# Load environment variables from .env file
source .env

# Function to convert bytes to human-readable format with one decimal place
fmt_size() {
    local size=$1
    if [ $size -lt 1024 ]; then
        printf "%.1f B" "$size"
    elif [ $size -lt 1048576 ]; then
        printf "%.1f KB" "$(echo "scale=1; $size / 1024" | bc)"
    elif [ $size -lt 1073741824 ]; then
        printf "%.1f MB" "$(echo "scale=1; $size / 1048576" | bc)"
    else
        printf "%.1f GB" "$(echo "scale=1; $size / 1073741824" | bc)"
    fi
}

# Use supplied argument as remote path if provided
if [ -n "$1" ]; then
    REMOTE_PATH=$1
fi

# List files in the remote path with their sizes
echo "Listing files in ${RCLONE_CONFIG_NAME}:${REMOTE_PATH} with their sizes:"
rclone ls ${RCLONE_CONFIG_NAME}:${REMOTE_PATH} --config "$RCLONE_CONFIG_PATH" | while read -r size path; do
    printf "%-8s\t%s\n" "$(fmt_size $size)" "$path"
done

# Calculate total occupied space
echo -e "\nCalculating total occupied space in ${RCLONE_CONFIG_NAME}:${REMOTE_PATH}:"
total_space=$(rclone size ${RCLONE_CONFIG_NAME}:${REMOTE_PATH} --config "$RCLONE_CONFIG_PATH" | grep 'Total size' | awk '{print $3}')
echo "Total occupied space: $total_space"

# Attempt to get remaining space (if supported)
echo -e "\nAttempting to calculate remaining space in ${RCLONE_CONFIG_NAME}:${REMOTE_PATH}:"
remaining_space=$(rclone about ${RCLONE_CONFIG_NAME}:${REMOTE_PATH} --config "$RCLONE_CONFIG_PATH" | grep 'Free space' | awk '{print $3}')

# Check if remaining_space is not empty
if [ -z "$remaining_space" ]; then
    echo "Remaining space information not available."
else
    echo "Remaining space: $remaining_space"
fi

echo -e "\nStatistics gathering completed."
