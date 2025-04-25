#!/bin/bash

# Description:
# This script performs backups of specified application directories, uploads the backups to a remote location using rclone,
# and cleans up old backups both locally and remotely. It checks for changes in the directories and creates backups only if changes are found.

set -euo pipefail
trap 'echo "❌ Error occurred on line $LINENO. Exiting."' ERR

# Load environment variables from .env file
source .env

# Default log file if not specified
LOG_FILE="${LOG_FILE:-/var/log/backup_script.log}"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

# Announce an action in the log
announce_action() {
    local action="$1"
    log "🔔 Starting action: $action"
}

# Check if required external tools are installed
check_required_tools() {
    local missing_tools=()
    
    # List of required tools
    local required_tools=("rclone" "bc" "zip")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ "${#missing_tools[@]}" -gt 0 ]; then
        log "❌ The following required tools are missing: ${missing_tools[*]}"
        log "Please install them and try again. Example installation commands:"
        
        if [ -x "$(command -v apt)" ]; then
            log "sudo apt-get install ${missing_tools[*]}"
        elif [ -x "$(command -v yum)" ]; then
            log "sudo yum install ${missing_tools[*]}"
        elif [ -x "$(command -v pacman)" ]; then
            log "sudo pacman -S ${missing_tools[*]}"
        else
            log "Manual installation required for: ${missing_tools[*]}"
        fi
        exit 1
    fi
}

# Check if dependency scripts exist and are executable
check_scripts() {
    for script in "$UPLOAD_SCRIPT" "$CLEANING_SCRIPT" "$STATS_SCRIPT"; do
        [[ -x "$script" ]] || { log "Required script $script not found or not executable."; exit 1; }
    done
}

# Function to check for changes and create backup if needed
backup_if_changed() {
    local app_path=$1
    local app_name
    app_name=$(basename "$app_path")
    local last_backup_file="${LOCAL_BACKUP_PATH}/${app_name}_last_backup.txt"
    local current_backup_file="${LOCAL_BACKUP_PATH}/${app_name}_current.txt"

    mkdir -p "$LOCAL_BACKUP_PATH"

    # Create a file list for the current state of the directory
    find "$app_path" -type f -printf '%T@ %p\n' | sort -k 2 > "$current_backup_file"

    # Compare file list hashes for performance
    local hash_now
    local hash_then
    hash_now=$(sha256sum "$current_backup_file" | awk '{print $1}')
    
    # If no previous backup file, treat it as "changes detected"
    if [ ! -f "$last_backup_file" ]; then
        log "📦 No previous backup for $app_path. Creating initial backup."
    else
        hash_then=$(sha256sum "$last_backup_file" | awk '{print $1}')
    fi

    # If hashes don't match, create a new backup
    if [ "$hash_now" != "${hash_then:-$hash_now}" ]; then
        log "📂 Changes detected in $app_path. Creating new backup."
        local archive_file="${LOCAL_BACKUP_PATH}/${app_name}_$(date +%Y%m%d%H%M%S).zip"
        zip -rq "$archive_file" "$app_path"
        mv "$current_backup_file" "$last_backup_file"
        announce_action "Uploading new backup for $app_name"
        "$UPLOAD_SCRIPT" "$archive_file"
        announce_action "Cleaning up backups for $app_name"
        "$CLEANING_SCRIPT" "$LOCAL_BACKUP_PATH"
    else
        log "✅ No changes in $app_path. Skipping backup."
        rm -f "$current_backup_file"
    fi
}

# Ensure the backups match app_paths.txt
sync_backups_with_paths() {
    # Read the current list of app paths
    mapfile -t current_paths < "$LIST_FILE"
    
    # Loop over all backups and check if they match with current paths
    for backup_file in "$LOCAL_BACKUP_PATH"/*_last_backup.txt; do
        local app_name
        app_name=$(basename "$backup_file" "_last_backup.txt")
        local app_path
        app_path=$(grep -m 1 "$app_name" "$LIST_FILE" || true)

        # If the app name is not found in the list file, delete its backup
        if [ -z "$app_path" ]; then
            log "🧹 Backup for $app_name not found in $LIST_FILE. Deleting the backup."
            rm -f "$backup_file"
            rm -f "${LOCAL_BACKUP_PATH}/${app_name}_current.txt"
        fi
    done
}

# Make sure all required tools are installed
check_required_tools

# Make sure all dependency scripts are present and executable
check_scripts

# Synchronize backups with the current app paths list
sync_backups_with_paths

# Read each app path and process it
while IFS= read -r app_path; do
    if [ -d "$app_path" ]; then
        backup_if_changed "$app_path"
    else
        log "⚠️ Directory $app_path does not exist. Skipping."
    fi
done < "$LIST_FILE"

# End with storage stats
announce_action "Publishing storage statistics"
"$STATS_SCRIPT"

log "🎉 Backup process complete."