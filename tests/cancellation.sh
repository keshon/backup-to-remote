#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
runner=''
cleanup() {
    if [[ -n $runner ]]; then kill -TERM "$runner" 2>/dev/null || true; wait "$runner" || true; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/source" "$tmp/bin" "$tmp/cloud"
printf 'data\n' > "$tmp/source/file"
export REAL_TAR REAL_RCLONE DOCKER_STATE READY TAR_CALLS
REAL_TAR=$(command -v tar)
REAL_RCLONE=$(command -v rclone)
DOCKER_STATE="$tmp/docker-state"
READY="$tmp/ready"
TAR_CALLS="$tmp/tar-calls"
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
case $1 in
    inspect) if [[ ${2:-} == --format ]]; then cat "$DOCKER_STATE"; else echo '{}'; fi ;;
    stop) echo false > "$DOCKER_STATE" ;;
    start) echo true > "$DOCKER_STATE" ;;
    *) exit 1 ;;
esac
EOF
cat > "$tmp/bin/tar" <<'EOF'
#!/usr/bin/env bash
calls=$(cat "$TAR_CALLS")
calls=$((calls + 1))
printf '%s\n' "$calls" > "$TAR_CALLS"
if [[ $DELAY_STAGE == archive && $calls == 2 ]]; then
    echo "$$" > "$READY"
    sleep 120 &
    wait
fi
exec "$REAL_TAR" "$@"
EOF
cat > "$tmp/bin/rclone" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ $DELAY_STAGE == upload && $arg == copyto ]]; then
        echo "$$" > "$READY"
        sleep 120 &
        wait
    fi
done
exec "$REAL_RCLONE" "$@"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" RCLONE_CONFIG_CONTENT
RCLONE_CONFIG_CONTENT=$(printf '[fixture]\ntype = local\n' | base64 -w0)
# Job control gives the background supervisor normal SIGINT handling for this test.
set -m
for stage in archive upload; do
    export DELAY_STAGE=$stage
    printf 'true\n' > "$DOCKER_STATE"
    printf '0\n' > "$TAR_CALLS"
    rm -f "$READY"
    cat > "$tmp/config" <<EOF
SERVER_ID=cancel-test
REMOTE=fixture:$tmp/cloud
STATE_DIR='$tmp/state-$stage'
RESERVE_MIB=1
app sample '$tmp/source' --stop fixture-db
EOF
    bash "$ROOT/backup.sh" --config "$tmp/config" --json > "$tmp/result" 2> "$tmp/progress" &
    runner=$!
    for ((i=0; i<200; i++)); do
        [[ ! -s $READY ]] || break
        sleep 0.05
    done
    [[ -s $READY ]] || { cat "$tmp/progress" >&2; echo 'Worker did not reach delayed stage' >&2; exit 1; }
    if [[ $stage == archive ]]; then
        # Like Ctrl+C, signal the supervisor while the child pipeline is blocked.
        kill -INT "$runner"
    else
        timeout 15 bash "$ROOT/backup.sh" stop --config "$tmp/config"
    fi
    # Do not let a broken cancellation hang CI for the fixture's full sleep.
    for ((i=0; i<200; i++)); do
        kill -0 "$runner" 2>/dev/null || break
        sleep 0.05
    done
    if kill -0 "$runner" 2>/dev/null; then echo 'Cancellation did not finish promptly' >&2; exit 1; fi
    if wait "$runner"; then echo 'Cancelled run reported success' >&2; exit 1; fi
    runner=''
    [[ $(cat "$DOCKER_STATE") == true ]]
    [[ ! -e $tmp/state-$stage/stopped-containers && ! -e $tmp/state-$stage/run.pid ]]
    [[ ! -e $tmp/state-$stage/apps/sample.json ]]
    [[ -z $(find "$tmp/state-$stage" -maxdepth 1 -name 'run.*' -type d -print) ]]
    jq -e '.status == "failed" and .temporary_files_cleaned' "$tmp/result"
    # Remaining lock inode is harmless: no child may retain an active lock.
    flock -n "$tmp/state-$stage/run.lock" true
    # Ordinary next run works without removing any lock file.
    export DELAY_STAGE=none
    bash "$ROOT/backup.sh" --config "$tmp/config" --json > "$tmp/result"
    jq -e '.status == "success"' "$tmp/result"
done
printf 'Cancellation during archive and upload passed.\n'
