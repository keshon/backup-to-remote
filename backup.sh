#!/bin/bash
set -euo pipefail
trap 'error "Error occurred on line $LINENO. Exiting."' ERR

# Load environment and libraries
source .env
source lib/logging.sh
source lib/dependencies.sh
source lib/rclone_utils.sh

# Initialize logging and dependencies
check_dependencies
init_rclone

# Ensure scripts exist
for script in "$UPLOAD_SCRIPT" "$CLEANING_SCRIPT" "$STATS_SCRIPT"; do
    [[ -x "$script" ]] || { error "Script $script not found or not executable"; exit 1; }
done

mkdir -p "$LOCAL_BACKUP_PATH"

# Sync backups with app_paths.txt
sync_backups() {
    mapfile -t current_paths < "$LIST_FILE"

    for backup_file in "$LOCAL_BACKUP_PATH"/*_last_backup.txt; do
        local app_name=$(basename "$backup_file" "_last_backup.txt")
        local found=false
        for path in "${current_paths[@]}"; do
            [[ "$path" == *"$app_name"* ]] && found=true && break
        done
        if ! $found; then
            info "Deleting outdated backup $app_name"
            rm -f "$backup_file" "${LOCAL_BACKUP_PATH}/${app_name}_current.txt"
        fi
    done
}

# Backup if changed
backup_if_changed() {
    local app_path=$1
    local app_name
    app_name=$(basename "$app_path")
    local last_backup="${LOCAL_BACKUP_PATH}/${app_name}_last_backup.txt"
    local current_backup="${LOCAL_BACKUP_PATH}/${app_name}_current.txt"

    find "$app_path" -type f -printf '%T@ %p\n' | sort -k2 > "$current_backup"

    if [ ! -f "$last_backup" ] || [ "$(sha256sum "$last_backup" | awk '{print $1}')" != "$(sha256sum "$current_backup" | awk '{print $1}')" ]; then
        info "Changes detected for $app_name. Creating backup."
        local archive="${LOCAL_BACKUP_PATH}/${app_name}_$(date +%Y%m%d%H%M%S).zip"
        zip -rq "$archive" "$app_path"
        mv "$current_backup" "$last_backup"

        info "Uploading backup $archive"
        "$UPLOAD_SCRIPT" "$archive"

        info "Cleaning backups for $app_name"
        "$CLEANING_SCRIPT" "$LOCAL_BACKUP_PATH"
    else
        info "No changes in $app_name. Skipping."
        rm -f "$current_backup"
    fi
}

# Main
sync_backups
while IFS= read -r path; do
    [ -d "$path" ] && backup_if_changed "$path" || warn "Directory $path does not exist"
done < "$LIST_FILE"

info "Publishing storage statistics"
"$STATS_SCRIPT"
info "Backup process complete"
