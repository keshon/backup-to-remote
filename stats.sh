#!/bin/bash

# Description:
# This script shows statistics of the specified remote folder, including
# a list of files and their sizes, total occupied space, and remote storage info (used, total, free).

# Load environment variables from .env file
source .env

# Function to convert bytes to human-readable format using binary units
fmt_size() {
    local size=$1
    awk -v size="$size" '
    function human(x, suffix) {
        printf "%.1f %s", x, suffix
        exit
    }
    BEGIN {
        if (size < 1024) human(size, "B")
        else if (size < 1048576) human(size / 1024, "KiB")
        else if (size < 1073741824) human(size / 1048576, "MiB")
        else human(size / 1073741824, "GiB")
    }'
}


# Use supplied argument as remote path if provided
if [ -n "$1" ]; then
    REMOTE_PATH=$1
fi

# Header
echo "Remote: ${RCLONE_CONFIG_NAME}"
echo "Path: /${REMOTE_PATH}"
printf "\n%-10s\t%s\n" "Size" "File"
echo "-------------------------------------------"

# List files with formatted sizes
rclone ls "${RCLONE_CONFIG_NAME}:${REMOTE_PATH}" --config "$RCLONE_CONFIG_PATH" | while read -r size path; do
    printf "%-10s\t%s\n" "$(fmt_size "$size")" "$path"
done

# Total occupied space (matching binary units)
total_size=$(rclone size "${RCLONE_CONFIG_NAME}:${REMOTE_PATH}" --config "$RCLONE_CONFIG_PATH" | grep 'Total size' | awk '{print $3 " " $4}')
echo -e "\nOccupied space: $total_size"

# Remote capacity stats
echo -e "\nChecking remote storage info..."
about_output=$(rclone about "${RCLONE_CONFIG_NAME}:${REMOTE_PATH}" --config "$RCLONE_CONFIG_PATH")

total_remote=$(echo "$about_output" | grep 'Total:' | awk '{print $2 " " $3}')
used_remote=$(echo "$about_output" | grep 'Used:' | awk '{print $2 " " $3}')
free_remote=$(echo "$about_output" | grep 'Free:' | awk '{print $2 " " $3}')

echo -e "Total space:   $total_remote"
echo -e "Used space:    $used_remote"
echo -e "Free space:    $free_remote"

echo -e "\nStatistics complete.\nNow go do something useful with your life.\n"
