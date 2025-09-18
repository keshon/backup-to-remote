#!/bin/bash
set -euo pipefail
source .env
source lib/rclone_utils.sh

init_rclone
verify_remote

# Convert bytes to human-readable format
fmt_size() {
    awk -v size="$1" 'BEGIN{
        if(size<1024) printf "%.1f B",size;
        else if(size<1048576) printf "%.1f KiB",size/1024;
        else if(size<1073741824) printf "%.1f MiB",size/1048576;
        else printf "%.1f GiB",size/1073741824
    }'
}

remote="${1:-$REMOTE_PATH}"

echo "Remote: ${RCLONE_CONFIG_NAME}"
echo "Path: /$remote"
echo

printf "%-10s\t%s\n" "Size" "File"
echo "-------------------------------------------"

# List files with formatted sizes
rclone ls "${RCLONE_CONFIG_NAME}:${remote}" --config "$RCLONE_CONFIG" | while read -r size path; do
    printf "%-10s\t%s\n" "$(fmt_size "$size")" "$path"
done

echo

# Total occupied space
total_size=$(rclone size "${RCLONE_CONFIG_NAME}:${remote}" --config "$RCLONE_CONFIG" | grep 'Total size' | awk '{print $3 " " $4}')
echo "Occupied space: $total_size"

# Remote capacity info
about=$(rclone about "${RCLONE_CONFIG_NAME}:${remote}" --config "$RCLONE_CONFIG")
total_remote=$(echo "$about" | grep 'Total:' | awk '{print $2 " " $3}')
used_remote=$(echo "$about" | grep 'Used:' | awk '{print $2 " " $3}')
free_remote=$(echo "$about" | grep 'Free:' | awk '{print $2 " " $3}')

echo
echo "Total space:   $total_remote"
echo "Used space:    $used_remote"
echo "Free space:    $free_remote"

echo -e "\nStatistics complete.\nNow go do something useful with your life.\n"
