#!/usr/bin/env bash

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; failure=$*; exit 1; }

bootstrap() {
    local tool
    local -a packages=()
    [[ $OSTYPE == linux* ]] || die 'Run this script on Ubuntu Linux. --help is available on other systems.'
    for tool in jq rclone tar gzip flock sha256sum base64 realpath du df sort stat timeout; do
        command -v "$tool" >/dev/null && continue
        case $tool in
            flock) packages+=(util-linux) ;;
            sha256sum|base64|realpath|du|df|sort|stat|timeout) packages+=(coreutils) ;;
            *) packages+=("$tool") ;;
        esac
    done
    ((${#packages[@]})) || return 0
    [[ -f /etc/os-release ]] || die 'Cannot identify this Linux distribution. Install jq rclone tar gzip coreutils util-linux manually.'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == ubuntu ]] || die 'Automatic dependency installation supports Ubuntu. Install jq rclone tar gzip coreutils util-linux manually.'
    local -a elevate=()
    if ((EUID != 0)); then
        command -v sudo >/dev/null && sudo -n true 2>/dev/null || die 'Missing tools need installation. Run this command once with sudo, preserving RCLONE_CONFIG_CONTENT if supplied.'
        elevate=(sudo -n)
    fi
    log "Installing missing tools: ${packages[*]}"
    "${elevate[@]}" apt-get update >&2
    "${elevate[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" ca-certificates >&2
}

declare -a APP_IDS=()
declare -A APP_PATHS=() APP_STOPS=() APP_EXCLUDES=()

app() {
    (($# >= 2)) || die 'An app needs a name and a folder. Example: app melodix /opt/dockers/melodix --stop melodix-app-1'
    local id=$1 path=$2
    shift 2
    [[ $id =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "Invalid app name: $id. Use letters, digits, dots, hyphens, or underscores."
    [[ ! ${APP_PATHS[$id]+exists} ]] || die "App $id is listed twice. Give each app a unique name."
    APP_IDS+=("$id")
    APP_PATHS[$id]=$path
    APP_STOPS[$id]=''
    APP_EXCLUDES[$id]=''
    while (($#)); do
        (($# >= 2)) && [[ -n $2 && $2 != *$'\n'* ]] || die "App $id: $1 needs a value on the same line."
        case $1 in
            --stop)
                [[ $2 =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "App $id: invalid container name."
                APP_STOPS[$id]+="$2"$'\n' ;;
            --exclude) APP_EXCLUDES[$id]+="$2"$'\n' ;;
            *) die "App $id: unknown option $1. Use --stop CONTAINER or --exclude PATTERN." ;;
        esac
        shift 2
    done
}

load_settings() {
    local file=$1
    [[ -f $file ]] || die "Settings not found: $file. Run bash backup.sh init, edit backup.conf, then try again."
    SERVER_ID=''
    REMOTE=''
    STATE_DIR=/var/lib/backup-to-remote
    KEEP=3
    RESERVE_MIB=512
    TIMEOUT_SECONDS=14400
    # This is a trusted shell settings file, not arbitrary input from n8n.
    # shellcheck disable=SC1090
    source "$file"
    [[ $SERVER_ID =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && $SERVER_ID != change-me ]] || die "Set SERVER_ID in $file, for example SERVER_ID=backtobed."
    [[ $REMOTE =~ ^[a-zA-Z0-9_-]+:.+ && $REMOTE != *$'\n'* ]] || die "Set REMOTE in $file to a remote and folder, for example REMOTE=union-koofr:backups."
    [[ $REMOTE != *'/../'* && $REMOTE != */.. ]] || die 'REMOTE must not contain parent-directory traversal.'
    REMOTE=${REMOTE%/}
    [[ $KEEP =~ ^[1-9][0-9]*$ && $RESERVE_MIB =~ ^[1-9][0-9]*$ && $TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || die 'KEEP, RESERVE_MIB, and TIMEOUT_SECONDS must be positive integers.'
    [[ $STATE_DIR == /* && $STATE_DIR != / ]] || die 'STATE_DIR must be an absolute folder such as /var/lib/backup-to-remote.'
    STATE_DIR=$(realpath -m -- "$STATE_DIR")
    [[ $STATE_DIR != / ]] || die 'STATE_DIR resolves to /. Choose a dedicated working folder.'
    ((${#APP_IDS[@]})) || die "No apps selected in $file. Add: app melodix /opt/dockers/melodix"
}

validate_sources() {
    local id path container
    for id in "${APP_IDS[@]}"; do
        path=${APP_PATHS[$id]}
        [[ $path == /* && -d $path && $path != *$'\n'* ]] || die "App $id: folder is missing or not absolute: $path. Fix its app line in the settings file."
        path=$(realpath -e -- "$path")
        [[ $STATE_DIR != "$path" && $STATE_DIR != "$path/"* && $path != "$STATE_DIR/"* && $path != / ]] || die "App $id overlaps the working folder. Move STATE_DIR outside every source folder."
        APP_PATHS[$id]=$path
        if [[ -n ${APP_STOPS[$id]} ]]; then
            command -v docker >/dev/null || die "App $id needs Docker to stop its containers, but docker was not found."
            while IFS= read -r container; do
                [[ -n $container ]] || continue
                docker inspect "$container" >/dev/null || die "App $id: cannot inspect container $container. Check its name and Docker permissions."
            done <<< "${APP_STOPS[$id]}"
        fi
    done
}

load_credentials() {
    local encoded=${RCLONE_CONFIG_CONTENT:-}
    if [[ -z $encoded && -t 0 ]]; then
        printf 'Paste the base64 rclone config (hidden; used only for this run): ' >&2
        IFS= read -rs encoded
        printf '\n' >&2
    fi
    [[ -n $encoded ]] || die 'Cloud credentials were not supplied. Set RCLONE_CONFIG_CONTENT for this run in n8n, or run in a terminal for a hidden prompt. Do not put credentials in backup.conf.'
    rclone_settings=$(printf '%s' "$encoded" | base64 --decode) || die 'RCLONE_CONFIG_CONTENT is not valid base64. Encode the original rclone config again.'
    [[ -n $rclone_settings ]] || die 'The decoded rclone config is empty.'
    unset RCLONE_CONFIG_CONTENT RCLONE_CONFIG RCLONE_PASSWORD_COMMAND
    export -n rclone_settings
}

rclone_run() {
    timeout --foreground "$TIMEOUT_SECONDS" rclone --config <(printf '%s\n' "$rclone_settings") "$@"
}

show_result() {
    jq -r '"Backup \(.status) · \(.server_id)", (.apps[] | "  \(.id): \(if .unchanged then "unchanged" else "saved " + .archive end)"), (if .error then "Error: " + .error else "Temporary files: cleaned" end)' "$1"
}
