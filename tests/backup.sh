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
cat > "$tmp/bin/rclone" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ $arg == copyto && ${FAIL_UPLOAD:-} == 1 ]]; then echo 'simulated upload failure' >&2; exit 9; fi
    if [[ $arg == cat && ${FAIL_READBACK:-} == 1 ]]; then echo 'wrong bytes'; exit 0; fi
done
exec "$real_rclone" "$@"
EOF
chmod +x "$tmp/bin/rclone"
export PATH="$tmp/bin:$PATH"
before=$(sha256sum "$tmp/state/my-app.json")
printf 'second version\n' > "$tmp/source space/file"
export FAIL_UPLOAD=1
expect_failure
jq -e '.status == "failed" and .temporary_files_cleaned' "$tmp/result"
[[ $(sha256sum "$tmp/state/my-app.json") == "$before" ]]
assert_clean
unset FAIL_UPLOAD
export FAIL_READBACK=1
expect_failure
[[ $(sha256sum "$tmp/state/my-app.json") == "$before" ]]
assert_clean
unset FAIL_READBACK
run
jq -e '.status == "success" and (.apps[0].unchanged | not)' "$tmp/result"
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
printf "app database '%s/source space' --stop fixture-db\n" "$tmp" >> "$tmp/config"
export FAIL_START=1
expect_failure
[[ -f $tmp/state/stopped-containers ]]
jq -e '.status == "failed" and (.error | contains("restart"))' "$tmp/result"
unset FAIL_START
run
[[ $(cat "$DOCKER_STATE") == true && ! -e $tmp/state/stopped-containers ]]
printf 'false\n' > "$DOCKER_STATE"
run
[[ $(cat "$DOCKER_STATE") == false ]]
cat > "$tmp/bin/tar" <<'EOF'
#!/usr/bin/env bash
echo 'simulated unreadable source' >&2
exit 2
EOF
chmod +x "$tmp/bin/tar"
expect_failure
assert_clean
printf '\nArchive, restore, deduplication, retention, failure, lock and restart tests passed.\n'
