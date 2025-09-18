#!/bin/bash
set -euo pipefail
trap 'error "Error occurred on line $LINENO. Exiting."' ERR
source .env
source lib/logging.sh
source lib/rclone_utils.sh

ARCHIVE_PATH=${1:-}
[ -n "$ARCHIVE_PATH" ] || { echo "Usage: $0 <path-to-archive>"; exit 1; }

ARCHIVE_NAME=$(basename "$ARCHIVE_PATH")
init_rclone
verify_remote

info "Uploading $ARCHIVE_PATH to ${RCLONE_CONFIG_NAME}:${REMOTE_PATH}"
rclone copy "$ARCHIVE_PATH" "${RCLONE_CONFIG_NAME}:${REMOTE_PATH}" --progress --drive-chunk-size=512M --drive-pacer-burst=195 --drive-pacer-min-sleep=20000ms

info "Verifying upload"
rclone ls "${RCLONE_CONFIG_NAME}:${REMOTE_PATH}" | grep -q "$ARCHIVE_NAME" && {
    info "Upload verified. Deleting local archive"
    rm "$ARCHIVE_PATH"
} || {
    error "Upload verification failed. Local archive not deleted"
    exit 1
}
info "Upload completed"
