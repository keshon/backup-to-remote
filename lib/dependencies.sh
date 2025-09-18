#!/bin/bash
# check required packages

check_dependencies() {
    local missing_tools=()
    local required_tools=("rclone" "zip" "awk" "find" "sha256sum" "sort")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ "${#missing_tools[@]}" -gt 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        if command -v apt &>/dev/null; then
            echo "sudo apt-get install ${missing_tools[*]}"
        elif command -v yum &>/dev/null; then
            echo "sudo yum install ${missing_tools[*]}"
        elif command -v pacman &>/dev/null; then
            echo "sudo pacman -S ${missing_tools[*]}"
        else
            echo "Please install manually: ${missing_tools[*]}"
        fi
        exit 1
    fi
}
