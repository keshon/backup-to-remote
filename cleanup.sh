#!/bin/bash
set -euo pipefail
source .env
source lib/logging.sh
source lib/rclone_utils.sh

init_rclone
verify_remote

info "Cleaning old backups in remote path ${REMOTE_PATH}"
files=$(rclone ls "${RCLONE_CONFIG_NAME}:${REMOTE_PATH}")
tmp=$(mktemp)

echo "$files" | awk '{print $2}' | sort -t_ -k1,1 -k2r,2 > "$tmp"

prev_name=""
count=0
to_delete=()

while IFS= read -r file; do
    base=$(echo "$file" | sed 's/_[0-9]\{14\}\.zip$//')
    [[ "$base" == "$prev_name" ]] && ((count++)) || { prev_name="$base"; count=1; }
    ((count > COPIES_TO_KEEP)) && to_delete+=("$file")
done < "$tmp"

for f in "${to_delete[@]}"; do
    info "Deleting $f from remote storage"
    rclone delete "${RCLONE_CONFIG_NAME}:${REMOTE_PATH}/$f"
done

info "Removing old local backups"
find "$LOCAL_BACKUP_PATH" -type f -name "*.zip" -exec rm -v {} +

rm "$tmp"
info "Cleanup complete"
