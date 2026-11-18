#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"

usage() {
    cat <<'EOF'
Back up changed folders as independent .tar.gz archives.

Start here:
  bash backup.sh init                 Create backup.conf; edit it before running
  bash backup.sh plan                 Check folders and show what would run
  bash backup.sh                      Back up now (same as run)

Everyday use:
  bash backup.sh status               Read the last result; no cloud access
  bash backup.sh space                Read cloud capacity

Options:
  --config FILE                      Settings (default: backup.conf beside script)
  --json                             JSON on stdout; progress on stderr
  --force                            Save even if the folder is unchanged
  --help                             Show this guide

Ubuntu: missing tools are installed on first use with root or passwordless sudo.
No services, timers, or commands are installed. Run manually or through n8n.
Supply RCLONE_CONFIG_CONTENT (base64) per run, or paste it at the hidden prompt.
It is passed to rclone through a pipe, never written to a config file.
EOF
}

command=run
config="$SCRIPT_DIR/backup.conf"
json=false
force=false
if (($#)) && [[ $1 != -* ]]; then command=$1; shift; fi
while (($#)); do
    case $1 in
        --config)
            if (($# < 2)) || [[ -z $2 || $2 == --* ]]; then
                die '--config needs a filename. Example: --config /opt/scripts/backup-to-remote/backup.conf'
            fi
            config=$2; shift 2 ;;
        --json) json=true; shift ;;
        --force) force=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1. Run: bash backup.sh --help" ;;
    esac
done
case $command in
    help) usage; exit 0 ;;
    init)
        [[ ! -e $config ]] || die "Settings already exist: $config. Edit that file; nothing was overwritten."
        cp -- "$SCRIPT_DIR/backup.conf.example" "$config"
        printf 'Settings created: %s\nEdit SERVER_ID, REMOTE, and the app lines, then run:\n  bash %q plan --config %q\n' "$config" "$SCRIPT_DIR/backup.sh" "$config"
        exit 0 ;;
    run|plan|status|space) ;;
    *) die "Unknown command: $command. Choose run, plan, status, space, or init. Run: bash backup.sh --help" ;;
esac

bootstrap
load_settings "$config"
if [[ $command == status ]]; then
    [[ -f $STATE_DIR/last-run.json ]] || die 'No saved run yet. Start with: bash backup.sh plan'
    if $json; then cat -- "$STATE_DIR/last-run.json"; else show_result "$STATE_DIR/last-run.json"; fi
    exit 0
fi
if [[ $command == plan ]]; then
    validate_sources
    printf 'VPS: %s\nDestination: %s/%s/\n' "$SERVER_ID" "$REMOTE" "$SERVER_ID"
    for id in "${APP_IDS[@]}"; do
        printf '\n%s: %s\n' "$id" "${APP_PATHS[$id]}"
        if [[ -n ${APP_STOPS[$id]} ]]; then printf '  Briefly stop: %s\n' "${APP_STOPS[$id]//$'\n'/, }"; else printf '  Copy live files (use --stop for databases and WAL stores).\n'; fi
    done
    printf '\nNo files uploaded or containers stopped. Keep %s archives per app.\n' "$KEEP"
    exit 0
fi
load_credentials
if [[ $command == space ]]; then
    rclone_run about "$REMOTE" --json | jq '{status:"success",total_bytes:.total,used_bytes:.used,free_bytes:.free}'
    exit 0
fi

mkdir -p -- "$STATE_DIR"
exec 9>"$STATE_DIR/run.lock"
flock -n 9 || die 'A backup is already running on this VPS. Wait for it to finish; do not delete run.lock.'
work=$(mktemp -d "$STATE_DIR/run.XXXXXXXX")
results='[]'
failure=''
current_app=''
started=$(date +%s)
trap finish EXIT
trap 'failure="Interrupted. Containers will be restarted before exit."; exit 130' INT
trap 'failure="Terminated. Containers will be restarted before exit."; exit 143' TERM
trap 'failure=${failure:-"An operation failed. Read $STATE_DIR/last-error.log on this VPS."}' ERR
exec 2> >(tee "$STATE_DIR/last-error.log" >&2)
recover_containers
validate_sources
for id in "${APP_IDS[@]}"; do
    current_app=$id
    backup_app "$id"
done
current_app=''
log 'All apps completed.'
