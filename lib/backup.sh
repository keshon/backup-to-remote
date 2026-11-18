#!/usr/bin/env bash

stop_run() {
    local pid token current
    [[ -f $STATE_DIR/run.pid ]] || die "No active run was found in $STATE_DIR. There is no lock file to delete."
    read -r pid token < "$STATE_DIR/run.pid"
    [[ $pid =~ ^[0-9]+$ && $token =~ ^[0-9]+$ ]] || die "Invalid run record: $STATE_DIR/run.pid. Check running processes before removing that record."
    current=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null) || current=''
    [[ $current == "$token" ]] || die "The recorded backup process has exited. If a child is still running, inspect it with ps before starting another backup."
    kill -TERM "$pid" || die "Cannot stop process $pid. Run this command as the user who started the backup, or with sudo."
    log "Stop requested for process $pid. Waiting for cleanup and container restarts."
    # The supervisor holds this lock until its worker and recovery have finished.
    exec 8>"$STATE_DIR/run.lock"
    flock 8
    exec 8>&-
    log 'Backup stopped.'
}

cancel_run() {
    local code=$1
    trap '' INT TERM HUP
    log 'Stopping backup work; waiting for cleanup and container restarts.'
    if [[ -n $worker_pid ]]; then
        kill -TERM -- "-$worker_pid" 2>/dev/null || true
        wait "$worker_pid" || true
    fi
    exit "$code"
}

supervise_run() {
    local worker_pid='' code token
    mkdir -p -- "$STATE_DIR"
    exec 9>"$STATE_DIR/run.lock"
    flock -n 9 || die "A backup is already running. To cancel it: bash $SCRIPT_DIR/backup.sh stop --config $config. Lock: $STATE_DIR/run.lock (do not delete it)."
    trap 'rm -f -- "$STATE_DIR/run.pid"' EXIT
    trap 'cancel_run 130' INT
    trap 'cancel_run 143' TERM HUP
    # A separate process group lets cancellation reach tar/gzip/rclone pipelines.
    BACKUP_WORKER_PARENT=$$ setsid bash "$SCRIPT_DIR/backup.sh" "${original_args[@]}" <&0 &
    worker_pid=$!
    token=$(awk '{print $22}' "/proc/$$/stat")
    printf '%s %s\n' "$$" "$token" > "$STATE_DIR/run.pid"
    if wait "$worker_pid"; then code=0; else code=$?; fi
    exit "$code"
}


recover_containers() {
    [[ -f $STATE_DIR/stopped-containers ]] || return 0
    local container failed=false
    while IFS= read -r container; do
        [[ -n $container ]] || continue
        log "Restarting $container."
        if ! docker start "$container" >&2; then failed=true; fi
    done < "$STATE_DIR/stopped-containers"
    if $failed; then
        failure="A container could not restart. Run docker start for the names in $STATE_DIR/stopped-containers. The journal has been kept."
        return 1
    fi
    rm -- "$STATE_DIR/stopped-containers"
}

stop_containers() {
    local id=$1 container running
    while IFS= read -r container; do
        [[ -n $container ]] || continue
        running=$(docker inspect --format '{{.State.Running}}' "$container")
        [[ $running == true ]] || continue
        # Record before stopping: a killed script can recover on the next run.
        printf '%s\n' "$container" >> "$STATE_DIR/stopped-containers"
        log "$id: stopping $container while preparing its archive."
        docker stop --time 30 "$container" >&2
    done <<< "${APP_STOPS[$id]}"
}

tar_app() {
    local id=$1 pattern code
    local -a excludes=()
    while IFS= read -r pattern; do
        [[ -n $pattern ]] && excludes+=(--exclude="$pattern")
    done <<< "${APP_EXCLUDES[$id]}"
    # Stable headers allow the archive stream to serve as the change fingerprint.
    if tar --sort=name --format=pax --numeric-owner --acls --xattrs \
        --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
        "${excludes[@]}" -C "${APP_PATHS[$id]}" -cf - .; then
        return 0
    else
        code=$?
    fi
    # GNU tar exit 1 means files changed; exit 2 still signals a fatal error.
    if $allow_live_changes && ((code == 1)); then
        log "$id: accepting changes reported by tar (--allow-live-changes)."
        return 0
    fi
    return "$code"
}

digest() { sha256sum | cut -d ' ' -f 1; }

check_space() {
    local id=$1 size free required
    size=$(du -sb --apparent-size -- "${APP_PATHS[$id]}" | cut -f 1)
    free=$(df -PB1 -- "$STATE_DIR" | awk 'NR==2 {print $4}')
    required=$((size + size / 10 + 67108864 + RESERVE_MIB * 1048576))
    [[ $free =~ ^[0-9]+$ && $free -ge $required ]] || die "App $id needs about $((required / 1048576)) MiB free for its archive and reserve; only $((free / 1048576)) MiB is available in $STATE_DIR. Free space or move STATE_DIR."
}

record_app() {
    local id=$1 archive=$2 bytes=$3 unchanged=$4 verification=${5:-previous-archive-size}
    results=$(jq -c --arg id "$id" --arg archive "$archive" --argjson bytes "$bytes" --argjson unchanged "$unchanged" --arg verification "$verification" \
        '. + [{id:$id,archive:$archive,data_added:$bytes,unchanged:$unchanged,status:"success",verification:$verification}]' <<< "$results")
}

prune_app() {
    local remote=$1 latest=$2 name count=1
    rclone_run lsf "$remote" --files-only --max-depth 1 > "$work/remote-files"
    LC_ALL=C sort -r "$work/remote-files" > "$work/sorted-files"
    while IFS= read -r name; do
        [[ $name =~ ^[0-9]{8}T[0-9]{6}Z-[a-zA-Z0-9]{8}\.tar\.gz$ ]] || continue
        [[ $name != "$latest" ]] || continue
        # Interrupted uploads without a completion checksum never displace good copies.
        grep -Fxq -- "$name.sha256" "$work/remote-files" || continue
        count=$((count + 1))
        ((count > KEEP)) || continue
        log "Removing older archive: $name"
        rclone_run deletefile "$remote/$name"
        rclone_run deletefile "$remote/$name.sha256"
    done < "$work/sorted-files"
}

backup_app() {
    local id=$1 fingerprint previous='' saved='' remote name archive packed_hash remote_hash stream_hash bytes verification
    local hash_check=${hash_check_override:-${APP_HASH_CHECK[$id]}} allow_live_changes=$allow_live_changes
    if ${APP_ALLOW_LIVE_CHANGES[$id]}; then allow_live_changes=true; fi
    remote="$REMOTE/$SERVER_ID/$id"
    log "$id: checking for changes."
    stop_containers "$id"
    fingerprint=$(tar_app "$id" | digest)
    if [[ -f $STATE_DIR/apps/$id.json ]]; then
        previous=$(jq -er '.fingerprint' "$STATE_DIR/apps/$id.json")
        saved=$(jq -er '.archive' "$STATE_DIR/apps/$id.json")
    fi
    if ! $force && [[ $fingerprint == "$previous" ]]; then
        recover_containers
        rclone_run lsjson "$remote/$saved" --stat > "$work/remote-stat.json"
        [[ $(jq -er '.Size' "$work/remote-stat.json") == "$(jq -er '.bytes' "$STATE_DIR/apps/$id.json")" ]] || die "App $id: the last remote archive has a different size. Run again with --force after checking cloud storage."
        log "$id: unchanged; last remote archive is present."
        record_app "$id" "$saved" 0 true
        prune_app "$remote" "$saved"
        return
    fi
    check_space "$id"
    name="$(date -u +%Y%m%dT%H%M%SZ)-${work##*.}.tar.gz"
    archive="$work/$name"
    log "$id: creating archive."
    (
        # Bound this archive's growth even if compression is ineffective.
        limit=$(df -PB1 -- "$STATE_DIR" | awk 'NR==2 {print $4}')
        limit=$(((limit - RESERVE_MIB * 1048576) / 1024))
        ((limit > 0)) || die "App $id: no space remains above the configured reserve."
        ulimit -f "$limit"
        tar_app "$id" | gzip -1 -n > "$archive"
    )
    stream_hash=$(gzip -dc -- "$archive" | digest)
    if [[ $stream_hash != "$fingerprint" ]]; then
        $allow_live_changes || die "App $id changed while archiving. Configure --stop for writer containers, or use --allow-live-changes for a best-effort live archive."
        log "$id: accepting a live archive; files changed during preparation."
    fi
    # Remember the stream we actually archived, not the earlier source scan.
    fingerprint=$stream_hash
    recover_containers
    bytes=$(stat -c %s -- "$archive")
    packed_hash=$(digest < "$archive")
    log "$id: uploading $name ($bytes bytes); containers have restarted."
    rclone_run copyto "$archive" "$remote/$name"
    verification=download-sha256
    if ! $hash_check; then
        log "$id: checking uploaded size; full readback skipped."
        rclone_run lsjson "$remote/$name" --stat > "$work/remote-stat.json"
        [[ $(jq -er '.Size' "$work/remote-stat.json") == "$bytes" ]] || die "App $id: uploaded size did not match. Local success state was not updated."
        verification=remote-size
    else
        log "$id: reading the uploaded archive back to verify SHA-256."
        remote_hash=$(rclone_run cat "$remote/$name" | digest)
        [[ $remote_hash == "$packed_hash" ]] || die "App $id: uploaded bytes did not match. Local success state was not updated; retry after checking cloud access."
    fi
    printf '%s  %s\n' "$packed_hash" "$name" | rclone_run rcat "$remote/$name.sha256"
    jq -n --arg fingerprint "$fingerprint" --arg archive "$name" --argjson bytes "$bytes" \
        '{fingerprint:$fingerprint,archive:$archive,bytes:$bytes}' > "$work/state.json"
    mv -- "$work/state.json" "$STATE_DIR/apps/$id.json"
    record_app "$id" "$name" "$bytes" false "$verification"
    prune_app "$remote" "$name"
    rm -- "$archive"
}

finish() {
    local code=$? cleaned=true status=success
    trap - EXIT ERR INT TERM
    if ! recover_containers; then code=1; fi
    if ! rm -rf -- "$work"; then cleaned=false; code=1; failure=${failure:-"Could not clean temporary files: $work"}; fi
    if ((code)); then status=failed; failure=${failure:-"Backup stopped during $current_app. Read $STATE_DIR/last-error.log."}; fi
    if jq -n --arg status "$status" --arg server "$SERVER_ID" --arg error "$failure" --arg app "$current_app" \
        --argjson apps "$results" --argjson cleaned "$cleaned" --argjson started "$started" \
        --argjson finished "$(date +%s)" \
        '{status:$status,server_id:$server,storage_mode:"archive",apps:$apps,temporary_files_cleaned:$cleaned,started_at:$started,completed_at:$finished} + (if $error == "" then {} else {error:$error,failed_app:$app} end)' \
        > "$STATE_DIR/last-run.json.tmp"; then
        mv -- "$STATE_DIR/last-run.json.tmp" "$STATE_DIR/last-run.json"
        if $json; then cat -- "$STATE_DIR/last-run.json"; else show_result "$STATE_DIR/last-run.json"; fi
    else
        log 'Could not save the run result. Check available space and state-directory permissions.'
        code=1
    fi
    exit "$code"
}
