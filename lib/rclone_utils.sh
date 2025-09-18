#!/bin/bash
# modular rclone helpers

# Initialize rclone configuration
init_rclone() {
    # Use environment overrides if set, otherwise fallback to .env
    local cfg_content="${RCLONE_CONFIG_CONTENT:-}"
    local cfg_path="${RCLONE_CONFIG_PATH:-}"
    local cfg_name="${RCLONE_CONFIG_NAME:-}"
    local remote="${REMOTE_PATH:-}"

    # Make them global for scripts
    export RCLONE_CONFIG_NAME="$cfg_name"
    export REMOTE_PATH="$remote"

    if [ -n "$cfg_content" ]; then
        local tmp_conf
        tmp_conf=$(mktemp)
        echo "$cfg_content" | base64 --decode > "$tmp_conf"
        export RCLONE_CONFIG="$tmp_conf"
    elif [ -n "$cfg_path" ]; then
        export RCLONE_CONFIG="$cfg_path"
    else
        echo "ERROR: Neither RCLONE_CONFIG_CONTENT nor RCLONE_CONFIG_PATH is set"
        exit 1
    fi
}

# Verify remote exists
verify_remote() {
    rclone ls "${RCLONE_CONFIG_NAME}:${REMOTE_PATH}" &>/dev/null || {
        echo "ERROR: Remote path ${RCLONE_CONFIG_NAME}:${REMOTE_PATH} is not accessible."
        exit 1
    }
}
