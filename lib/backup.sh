#!/usr/bin/env bash

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
    local id=$1 pattern
    local -a excludes=()
    while IFS= read -r pattern; do
        [[ -n $pattern ]] && excludes+=(--exclude="$pattern")
    done <<< "${APP_EXCLUDES[$id]}"
    # Stable headers allow the archive stream to serve as the change fingerprint.
    tar --sort=name --format=pax --numeric-owner --acls --xattrs \
        --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
        "${excludes[@]}" -C "${APP_PATHS[$id]}" -cf - .
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
    local id=$1 archive=$2 bytes=$3 unchanged=$4
    results=$(jq -c --arg id "$id" --arg archive "$archive" --argjson bytes "$bytes" --argjson unchanged "$unchanged" \
        '. + [{id:$id,archive:$archive,data_added:$bytes,unchanged:$unchanged,status:"success",verification:"download-sha256"}]' <<< "$results")
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
    local id=$1 fingerprint previous='' saved='' remote name archive packed_hash remote_hash stream_hash bytes
    remote="$REMOTE/$SERVER_ID/$id"
    log "$id: checking for changes."
    stop_containers "$id"
    fingerprint=$(tar_app "$id" | digest)
    if [[ -f $STATE_DIR/$id.json ]]; then
        previous=$(jq -er '.fingerprint' "$STATE_DIR/$id.json")
        saved=$(jq -er '.archive' "$STATE_DIR/$id.json")
    fi
    if ! $force && [[ $fingerprint == "$previous" ]]; then
        rclone_run lsjson "$remote/$saved" --stat > "$work/remote-stat.json"
        [[ $(jq -er '.Size' "$work/remote-stat.json") == "$(jq -er '.bytes' "$STATE_DIR/$id.json")" ]] || die "App $id: the last remote archive has a different size. Run again with --force after checking cloud storage."
        log "$id: unchanged; last remote archive is present."
        recover_containers
        record_app "$id" "$saved" 0 true
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
        tar_app "$id" | gzip -n > "$archive"
    )
    stream_hash=$(gzip -dc -- "$archive" | digest)
    [[ $stream_hash == "$fingerprint" ]] || die "App $id changed while archiving. No success was recorded. Configure --stop for its writer containers, then retry."
    recover_containers
    bytes=$(stat -c %s -- "$archive")
    packed_hash=$(digest < "$archive")
    log "$id: uploading $name ($bytes bytes); containers have restarted."
    rclone_run copyto "$archive" "$remote/$name"
    log "$id: reading the uploaded archive back to verify SHA-256."
    remote_hash=$(rclone_run cat "$remote/$name" | digest)
    [[ $remote_hash == "$packed_hash" ]] || die "App $id: uploaded bytes did not match. Local success state was not updated; retry after checking cloud access."
    printf '%s  %s\n' "$packed_hash" "$name" | rclone_run rcat "$remote/$name.sha256"
    jq -n --arg fingerprint "$fingerprint" --arg archive "$name" --argjson bytes "$bytes" \
        '{fingerprint:$fingerprint,archive:$archive,bytes:$bytes}' > "$work/state.json"
    mv -- "$work/state.json" "$STATE_DIR/$id.json"
    record_app "$id" "$name" "$bytes" false
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
