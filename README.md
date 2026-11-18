# Backup to Remote

Bash scripts for backing up Ubuntu VPS folders to rclone storage, including a
union of cloud accounts. Each changed app gets a complete `.tar.gz` archive.
Download it and unpack it with tar or 7-Zip.

Run backups manually or through n8n. The script installs missing tools with apt
on first use; it does not install a service, timer, or backup gateway.

## Set up a VPS

On the target VPS:

```bash
git clone https://github.com/keshon/backup-to-remote.git /opt/scripts/backup-to-remote
cd /opt/scripts/backup-to-remote
bash backup.sh init
nano backup.conf
```

Choose a unique server name, your existing rclone remote and destination folder,
and the apps to include:

```bash
SERVER_ID=backtobed
REMOTE=union-koofr:backups
STATE_DIR=/var/lib/backup-to-remote
KEEP=3
RESERVE_MIB=512
TIMEOUT_SECONDS=14400

app back2bed-prod /opt/dockers/back2bed-prod --stop back2bed-prod
app website /opt/dockers/keshon.ru --exclude './logs'
```

`backup.conf` contains trusted Bash settings. Quote paths and patterns containing
spaces or wildcards. Add or remove `app` lines to change the selection. Repeat
`--stop` for multiple writer containers or `--exclude` for multiple patterns.
Use the actual container names from `docker ps -a`.

```bash
sudo bash backup.sh plan
sudo bash backup.sh
```

The first command checks folders and container access without stopping anything
or contacting the cloud. Either command installs missing dependencies if needed:
Bash 4.4+, GNU tar/coreutils, gzip, util-linux, jq and rclone. Ubuntu is supported;
the automatic installation requires root or passwordless sudo. Docker must
already exist if you use `--stop`.

The backup command asks for a base64-encoded rclone configuration at a hidden
prompt. Prepare that value on the machine holding your cloud config:

```bash
base64 -w0 /path/to/rclone.conf
```

Supply it again for each manual run, or let n8n supply it as described below.
All remotes referenced by your union must be included in that configuration.
The script passes the INI settings to rclone through environment variables.
It never saves a cloud config on the target or reads the old `.env` or
`rclone.conf` files.

## Daily use

| Task | Command |
| --- | --- |
| Back up | `sudo bash backup.sh` (or `sudo bash backup.sh run`) |
| Preview apps and their checks | `sudo bash backup.sh plan` |
| Read the last result | `sudo bash backup.sh status` |
| Read cloud capacity | `sudo bash backup.sh space` |
| Create settings | `bash backup.sh init` |
| Show help | `bash backup.sh --help` (or `bash backup.sh help`) |

## Parameters and defaults

### Per-app options in backup.conf

| Parameter | Default | What it does |
| --- | --- | --- |
| `NAME` | Required | Unique app name in `app NAME FOLDER`. |
| `FOLDER` | Required | Absolute folder to back up. |
| `--stop CONTAINER` | OFF; no containers stopped | Stop a writer during scanning and copying. Repeat for multiple containers. |
| `--exclude PATTERN` | OFF; nothing excluded | Exclude a tar pattern. Repeat for multiple patterns. |
| `--skip-hash-check` | OFF; full hash check ON | Skip downloading the uploaded archive. Check its size and save the local checksum. |
| `--allow-live-changes` | OFF; reject changing files | Accept changes between scanning and copying, including GNU tar's changed-file warnings. Live database copies may be inconsistent. |

### Command-line options

| Parameter | Default | What it does |
| --- | --- | --- |
| `--config FILE` | `backup.conf` beside the script | Read another settings file. |
| `--json` | OFF; readable output | Write JSON to stdout and progress to stderr. Applies to run, status and space. |
| `--force` | OFF; skip unchanged apps | Create a new archive even if the app is unchanged. |
| `--skip-hash-check` | OFF | Skip the full uploaded hash check for every app in this run. |
| `--allow-live-changes` | OFF | Accept changing files for every app in this run. |
| `--help`, `-h` | OFF | Show help and exit. |

Command-line skip options apply to every app. An app without either option keeps
both checks enabled unless a command-line option overrides it. Neither option
cancels configured container stops. `plan` shows the effective checks per app.

### Settings and credentials

| Parameter | Default | What it does |
| --- | --- | --- |
| `SERVER_ID` | Required | Unique VPS name used in the cloud path. Replace `change-me` in the example. |
| `REMOTE` | Required | Existing rclone remote and folder, for example `union-koofr:backups`. |
| `STATE_DIR` | `/var/lib/backup-to-remote` | Local results, fingerprints and temporary archives. Keep outside source folders. |
| `KEEP` | `3` | Completed archives to retain per app. Must be a positive integer. |
| `RESERVE_MIB` | `512` | Free-space reserve in MiB. Must be a positive integer. |
| `TIMEOUT_SECONDS` | `14400` (4 hours) | Timeout per rclone command, not for the whole backup. Must be a positive integer. |
| `RCLONE_CONFIG_CONTENT` | Unset; hidden prompt in a terminal | Base64 rclone INI supplied through the environment. Required for unattended cloud operations. |
| Compression | ON; gzip level 6 | All archives are `.tar.gz`. There is no compression switch. |

## How backups work

Change detection reads file contents and archived metadata, including permissions,
ownership, symlinks and empty folders. A changed app gets a full archive. An
unchanged app is skipped after checking that its previous remote archive still
exists with the saved size. Use `--force` to save another copy.

For apps with `--stop`, the script stops only containers that were running. They
stay stopped during fingerprinting and archive creation, including a brief
fingerprint scan on unchanged runs. They restart before uploading. Initially
stopped containers remain stopped. For databases and WAL stores, stop every
writer, including processes outside the configured containers. A mapped data folder alone does not
make a live database copy consistent.

Apps are processed one at a time. The script estimates required scratch space
and reserves `RESERVE_MIB`, then limits archive file growth to the available
space above that reserve. Other processes can still consume space concurrently.
Temporary files are removed on ordinary success and failure. After a power loss
or SIGKILL, a `run.*` scratch folder may remain in `STATE_DIR`.

The script compares a scan taken before compression with the archive it creates.
Logs or database writes between those reads can fail the run. To accept a live
copy for one app and skip its full upload check, use:

```bash
app website /opt/dockers/keshon.ru --skip-hash-check --allow-live-changes
app database /opt/dockers/database --stop database-db-1
```

Here only `website` skips those checks; `database` keeps them enabled. n8n reads
the same settings, so its command needs no changes.

By default, the script downloads each upload and checks its SHA-256 before
recording success. This adds another archive-sized transfer. With
`--skip-hash-check`, it checks the remote size instead. GNU tar errors other than
changed-file warnings still fail, even with `--allow-live-changes`.

After the selected check passes, the script saves the local checksum beside the
archive and applies `KEEP` retention. Archives without that completion file are
left for manual inspection and do not count toward retention. The latest
completed archive is always kept. A failed retention step retries on the next
run, including when the app is unchanged.

## n8n

Import [n8n/n8n_workflow_example.json](n8n/n8n_workflow_example.json).

1. Set the SSH credential on **Run backup1** and **Read cloud space1**. Both execute
   on the target VPS with access to the selected folders and Docker.
2. In **Settings**, fill `rcloneConfigBase64` with the encoded config from the
   machine holding your credentials. The example contains no credentials.
3. Check the script path in both SSH nodes if you used another checkout location.
4. Configure and enable **Discord1**. **Telegram1** stays disabled until you add its
   bot credential and chat ID. Each notification node can be toggled independently.
5. Click **Execute workflow** to test it, then publish for Wednesday at 05:00
   Moscow time. Edit the schedule node to change the time.

The workflow sends a coloured Discord embed, per-app results, uploaded bytes,
cloud capacity bar and Telegram HTML formatting. Backup failures stop the success
notification; a failed capacity query shows capacity as unavailable. Configure an
n8n error workflow if you also want failure alerts.

If you back up the n8n container itself with `--stop`, start that backup manually
or from another n8n instance. A workflow cannot reliably finish its notifications
after stopping its own orchestrator.

Credentials exist in memory on the target during execution. Base64 is encoding,
not encryption. The n8n Settings value and resolved SSH command can appear in
saved workflow/execution data; restrict access and set an appropriate execution
retention policy. This config transport suits remotes such as Koofr with static
credentials. Remotes that need to save refreshed OAuth tokens need another
credential arrangement.

There are no installed schedules to manage. Disable the workflow in n8n to stop
automatic backups. If migrating from the previous tool, separately disable its
old n8n workflow and timer so they no longer run.

## Restore

Cloud layout:

```text
backups/backtobed/back2bed-prod/
  20261118T050000Z-a1B2c3D4.tar.gz
  20261118T050000Z-a1B2c3D4.tar.gz.sha256
```

Download an archive and its checksum using the cloud website or rclone. On Linux:

```bash
sha256sum -c 20261118T050000Z-a1B2c3D4.tar.gz.sha256
mkdir restored
sudo tar --numeric-owner --acls --xattrs -xzpf 20261118T050000Z-a1B2c3D4.tar.gz -C restored
```

Each archive contains that app folder's contents. Inspect the extracted files,
stop the destination app, then move the restored data into place. Windows tools
can extract the files, but Linux is needed to restore Linux ownership and modes.
Archives are not encrypted by this script; cloud storage receives ordinary files.

## If something fails

The command exits nonzero. `--json` returns a failed result for errors occurring
inside a backup run; configuration and startup errors print to stderr and may
exit before a result can be created. n8n checks both exit status and JSON.

```bash
sudo bash backup.sh status
sudo tail -n 80 /var/lib/backup-to-remote/last-error.log
```

Use your configured `STATE_DIR` if different. A failed upload does not update the
saved fingerprint, so the next run tries again. A local `flock` prevents
overlapping runs on this VPS and releases automatically on exit; use a unique `SERVER_ID` on each VPS.

If a container cannot restart, its name remains in `STATE_DIR/stopped-containers`.
The next backup attempts those restarts first. You can also run `docker start`
for those names manually. A killed process cannot run cleanup, so check container
state after a forced termination before leaving the server unattended.

To update, run `git pull --ff-only` in the checkout. Your ignored `backup.conf`
is kept. Nothing is copied into `/usr/local` and there is no installer to rerun.
To remove the tool, disable its n8n workflow and remove the checkout. Keep or
remove `STATE_DIR` separately; it contains local results and change fingerprints.
Cloud archives are unaffected.

## Development

Run on Ubuntu with jq, rclone, shellcheck and Node.js installed:

```bash
shellcheck -x backup.sh stats.sh tests/backup.sh
bash tests/backup.sh
node --test tests/test_notifications.cjs
```

The Bash suite uses a temporary local rclone remote, never production credentials.
It checks extraction, metadata, change detection, uploads, retention and local
locking. Fake Docker commands exercise container restart recovery. GitHub Actions
runs these checks on Ubuntu 24.04. Test your cloud provider with disposable data
before adopting a deployment.

MIT license. See [LICENSE](LICENSE).
