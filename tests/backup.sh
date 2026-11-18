#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/source space/empty" "$tmp/cloud" "$tmp/bin"
printf 'first version\n' > "$tmp/source space/file"
chmod 640 "$tmp/source space/file"
ln -s file "$tmp/source space/link"
printf 'ignored\n' > "$tmp/source space/ignored.log"
cat > "$tmp/config" <<EOF
SERVER_ID=test-vps
REMOTE=fixture:$tmp/cloud
STATE_DIR='$tmp/state'
KEEP=2
RESERVE_MIB=1
TIMEOUT_SECONDS=60
app my-app '$tmp/source space' --exclude './ignored.log'
EOF
export RCLONE_CONFIG_CONTENT
RCLONE_CONFIG_CONTENT=$(printf '[fixture]\ntype = local\n' | base64 -w0)
run() { bash "$ROOT/backup.sh" run --config "$tmp/config" --json > "$tmp/result"; }
expect_failure() { if run; then printf 'Expected failure, got success\n' >&2; exit 1; fi; }
assert_clean() { [[ -z $(find "$tmp/state" -maxdepth 1 -type d -name 'run.*' -print) ]]; }

bash "$ROOT/backup.sh" plan --config "$tmp/config" > /dev/null
[[ ! -e $tmp/state ]]
run
jq -e '.status == "success" and .apps[0].unchanged == false and .temporary_files_cleaned' "$tmp/result"
name=$(jq -r '.apps[0].archive' "$tmp/result")
dest="$tmp/cloud/test-vps/my-app"
(cd "$dest" && sha256sum -c "$name.sha256")
mkdir "$tmp/restored"
tar -xzf "$dest/$name" -C "$tmp/restored"
cmp "$tmp/source space/file" "$tmp/restored/file"
[[ $(stat -c %a "$tmp/restored/file") == 640 && -L $tmp/restored/link && -d $tmp/restored/empty && ! -e $tmp/restored/ignored.log ]]
assert_clean
run
jq -e '.apps[0].unchanged and .apps[0].data_added == 0' "$tmp/result"
printf 'changed excluded file\n' > "$tmp/source space/ignored.log"
run
jq -e '.apps[0].unchanged' "$tmp/result"
chmod 600 "$tmp/source space/file"
run
jq -e '.apps[0].unchanged == false' "$tmp/result"

real_rclone=$(command -v rclone)
export real_rclone
# Exercise union and hyphenated remote names with environment-only configuration.
mkdir -p "$tmp/union-one" "$tmp/union-two"
sed -e "s|REMOTE=.*|REMOTE=fixture-union:backups|" -e "s|STATE_DIR=.*|STATE_DIR='$tmp/union-state'|" "$tmp/config" > "$tmp/union-config"
RCLONE_CONFIG_CONTENT=$(printf '[fixture-one]\ntype = local\n[fixture-two]\ntype = local\n[fixture-union]\ntype = union\nupstreams = fixture-one:%s/union-one fixture-two:%s/union-two\ncreate_policy = mfs\n' "$tmp" "$tmp" | base64 -w0)
bash "$ROOT/backup.sh" --config "$tmp/union-config" --json > "$tmp/union-result"
jq -e '.status == "success"' "$tmp/union-result"
RCLONE_CONFIG_CONTENT=$(printf '[fixture]\ntype = local\n' | base64 -w0)
cat > "$tmp/bin/rclone" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ $arg == copyto && ${FAIL_UPLOAD:-} == 1 ]]; then echo 'simulated upload failure' >&2; exit 9; fi
    if [[ $arg == cat && ${FAIL_READBACK:-} == 1 ]]; then echo 'wrong bytes'; exit 0; fi
    if [[ $arg == deletefile && ${FAIL_PRUNE:-} == 1 ]]; then echo 'simulated retention failure' >&2; exit 9; fi
    if [[ $arg == lsjson && ${CHECK_RUNNING:-} == 1 && $(cat "$DOCKER_STATE") != true ]]; then
        echo 'container was still stopped during cloud access' >&2
        exit 8
    fi
done
exec "$real_rclone" "$@"
EOF
chmod +x "$tmp/bin/rclone"
export PATH="$tmp/bin:$PATH"
before=$(sha256sum "$tmp/state/apps/my-app.json")
printf 'second version\n' > "$tmp/source space/file"
export FAIL_UPLOAD=1
expect_failure
jq -e '.status == "failed" and .temporary_files_cleaned' "$tmp/result"
[[ $(sha256sum "$tmp/state/apps/my-app.json") == "$before" ]]
assert_clean
unset FAIL_UPLOAD
export FAIL_READBACK=1
expect_failure
[[ $(sha256sum "$tmp/state/apps/my-app.json") == "$before" ]]
assert_clean
# The opt-out must not call cat, and must report its weaker verification.
bash "$ROOT/backup.sh" --config "$tmp/config" --json --skip-hash-check > "$tmp/result"
jq -e '.status == "success" and .apps[0].verification == "remote-size"' "$tmp/result"
unset FAIL_READBACK
run
jq -e '.status == "success" and .apps[0].unchanged' "$tmp/result"
[[ $(find "$dest" -name '*.tar.gz.sha256' | wc -l) -eq 2 ]]
cp "$tmp/config" "$tmp/no-space-config"
printf 'RESERVE_MIB=999999999\n' >> "$tmp/no-space-config"
before=$(sha256sum "$tmp/state/apps/my-app.json")
if bash "$ROOT/backup.sh" --force --config "$tmp/no-space-config" --json > "$tmp/result"; then
    printf 'Expected insufficient-space failure\n' >&2
    exit 1
fi
jq -e '.status == "failed" and (.error | contains("space")) and .temporary_files_cleaned' "$tmp/result"
[[ $(sha256sum "$tmp/state/apps/my-app.json") == "$before" ]]
assert_clean
printf 'third version\n' > "$tmp/source space/file"
export FAIL_PRUNE=1
expect_failure
[[ $(find "$dest" -name '*.tar.gz.sha256' | wc -l) -eq 3 ]]
unset FAIL_PRUNE
run
jq -e '.status == "success" and .apps[0].unchanged' "$tmp/result"
[[ $(find "$dest" -name '*.tar.gz.sha256' | wc -l) -eq 2 ]]
(
    exec 8>"$tmp/state/run.lock"
    flock -n 8
    expect_failure
)

# Model Docker state and a failed restart without stopping real applications.
export DOCKER_STATE="$tmp/docker-state"
printf 'true\n' > "$DOCKER_STATE"
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
case $1 in
    inspect) if [[ ${2:-} == --format ]]; then cat "$DOCKER_STATE"; else echo '{}'; fi ;;
    stop) echo false > "$DOCKER_STATE" ;;
    start) if [[ ${FAIL_START:-} == 1 ]]; then exit 1; fi; echo true > "$DOCKER_STATE" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/docker"
printf "app last-run '%s/source space' --stop fixture-db\n" "$tmp" >> "$tmp/config"
export FAIL_START=1
expect_failure
[[ -f $tmp/state/stopped-containers ]]
jq -e '.status == "failed" and (.error | contains("restart"))' "$tmp/result"
unset FAIL_START
run
[[ $(cat "$DOCKER_STATE") == true && ! -e $tmp/state/stopped-containers ]]
export CHECK_RUNNING=1
run
unset CHECK_RUNNING
printf 'false\n' > "$DOCKER_STATE"
run
[[ $(cat "$DOCKER_STATE") == false ]]
# Change the source after the first tar scan, before compression starts.
export REAL_TAR
REAL_TAR=$(command -v tar)
export TAR_CALLS="$tmp/tar-calls" LIVE_FILE="$tmp/source space/file"
printf '0\n' > "$TAR_CALLS"
cat > "$tmp/bin/tar" <<'EOF'
#!/usr/bin/env bash
calls=$(cat "$TAR_CALLS")
calls=$((calls + 1))
printf '%s\n' "$calls" > "$TAR_CALLS"
"$REAL_TAR" "$@"
code=$?
if ((calls == 1)); then printf 'live change\n' >> "$LIVE_FILE"; fi
if [[ ${TAR_CHANGED_EXIT:-} == 1 && $code == 0 ]]; then exit 1; fi
exit "$code"
EOF
chmod +x "$tmp/bin/tar"
if bash "$ROOT/backup.sh" --force --config "$tmp/config" --json > "$tmp/result"; then
    echo 'Expected live change rejection' >&2; exit 1
fi
printf '0\n' > "$TAR_CALLS"
export TAR_CHANGED_EXIT=1
bash "$ROOT/backup.sh" --force --config "$tmp/config" --json --allow-live-changes > "$tmp/result"
jq -e '.status == "success"' "$tmp/result"
# Saved fingerprint must describe the archive rather than the initial scan.
name=$(jq -r '.apps[0].archive' "$tmp/result")
expected=$(gzip -dc "$dest/$name" | sha256sum | cut -d ' ' -f 1)
[[ $(jq -r '.fingerprint' "$tmp/state/apps/my-app.json") == "$expected" ]]
unset TAR_CHANGED_EXIT
cat > "$tmp/bin/tar" <<'EOF'
#!/usr/bin/env bash
echo 'simulated unreadable source'  >&2
exit 2
EOF
chmod +x "$tmp/bin/tar"
expect_failure
if bash "$ROOT/backup.sh" --config "$tmp/config" --json --allow-live-changes > "$tmp/result"; then
    echo 'Fatal tar errors must not be ignored' >&2; exit 1
fi
assert_clean
printf '\nArchive, restore, deduplication, retention, failure, lock and restart tests passed.\n'
