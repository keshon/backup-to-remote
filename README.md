# Backup to Remote

Bash scripts for backing up Ubuntu VPS folders to rclone storage, including a
union of cloud accounts. Each changed app gets a complete `.tar.gz` archive.
Download it and unpack it with tar or 7-Zip.

No systemd installation, background service, enrollment, or backup gateway.
Missing command-line tools are installed with apt on first use. Run through n8n
or start a backup manually.

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

The backup command asks you to paste a **base64-encoded rclone configuration**
at a hidden prompt. Prepare that value on the machine holding your cloud config:

```bash
base64 -w0 /path/to/rclone.conf
```

Supply it again for each manual run, or let n8n supply it as described below.
All remotes referenced by your union must be included in that configuration.
The script converts the ordinary INI entries to rclone environment settings and never saves a target-side
rclone config. It does not read the old `.env` or `rclone.conf` files.

## Daily use

| Task | Command |
| --- | --- |
| Back up | `sudo bash backup.sh` |
| Preview selected apps | `sudo bash backup.sh plan` |
| Read the last result | `sudo bash backup.sh status` |
| Save a new archive even if unchanged | `sudo bash backup.sh --force` |
| Skip full upload download/check | `sudo bash backup.sh --skip-hash-check` |
| Accept files changing during copying | `sudo bash backup.sh --allow-live-changes` |
| Read cloud capacity | `sudo bash backup.sh space` |
| Use another settings file | `sudo bash backup.sh --config /absolute/path/backup.conf` |
| Get machine-readable results | `sudo bash backup.sh --json` |
| Show help | `bash backup.sh --help` |

Change detection reads the files and their archived metadata. It detects content,
permissions, ownership, symlinks, empty folders, additions and deletions. It avoids
uploading unchanged apps; it does not upload individual changed chunks. For an
unchanged app, it confirms that the last archive still exists with its saved size.
Use `--force` to upload and fully verify another copy.

For apps with `--stop`, the script stops only containers that were running. They
stay stopped during fingerprinting and archive creation, including a brief
fingerprint scan on unchanged runs. They restart before uploading. Initially
stopped containers remain stopped. Databases and custom WAL stores need this
consistency boundary; mapping their files into a folder alone is insufficient.
Other writers outside the configured containers must also be stopped by you.
Live folders that change during the scan or archive can cause a failed run.

Apps are processed one at a time. The script estimates required scratch space
and reserves `RESERVE_MIB`, then limits archive file growth to the available
space above that reserve. Other processes can still consume space concurrently.
Temporary files are removed on ordinary success and failure. After a power loss
or SIGKILL, a `run.*` scratch folder may remain in `STATE_DIR`.

Archives use gzip compression (the default gzip level, 6).

`--skip-hash-check` checks the remote size instead of downloading the upload. The
local SHA-256 sidecar is still saved for restore checks, but uploaded content is
not fully verified. `--allow-live-changes` accepts a mismatch between the initial
scan and archived content, and GNU tar warnings about changing files. Other tar
errors still fail. This is a best-effort copy: live databases may be inconsistent.
Configured `--stop` containers still stop; this flag does not override them.
Both flags can be combined. For n8n, append them after `run --json` in the
**Run backup** command. Defaults keep both checks enabled.

Each upload is downloaded through rclone and SHA-256 checked before the script
records success. This doubles archive transfer traffic. Only then does it apply
`KEEP` retention within that server/app folder. Archives without a completion
checksum, such as interrupted uploads, are left for manual inspection and do not
count toward retention. The latest completed archive is always retained. With `--skip-hash-check`, completion
means a size check rather than a full content check.

## n8n

Import [n8n/n8n_workflow_example.json](n8n/n8n_workflow_example.json).

1. Set the SSH credential on **Run backup** and **Read cloud space**. Both execute
   on the target VPS with access to the selected folders and Docker.
2. In **Settings**, fill `rcloneConfigBase64` with the encoded config from the
   machine holding your credentials. The example contains no credentials.
3. Check the script path in both SSH nodes if you used another checkout location.
4. Configure and enable **Discord**. **Telegram** stays disabled until you add its
   bot credential and chat ID. Each notification node can be toggled independently.
5. Test **Manual backup**, then publish the Wednesday 05:00 Moscow schedule if wanted.

The workflow keeps the coloured Discord embed, per-app results, uploaded bytes,
cloud capacity bar and Telegram HTML formatting. Backup failures stop the success
notification; a failed capacity query shows capacity as unavailable. Configure an
n8n error workflow if you also want failure alerts.

If you back up the n8n container itself with `--stop`, start that backup manually
or from another n8n instance. A workflow cannot reliably finish its notifications
after stopping its own orchestrator.

Credentials exist in memory on the target during execution. Base64 is encoding,
not encryption. The n8n Settings value and resolved SSH command can appear in
saved workflow/execution data; restrict access and set an appropriate execution
retention policy. The script cannot prevent n8n from storing its own inputs.
This config transport suits remotes such as Koofr with static credentials; remotes
that need to save refreshed OAuth tokens need another credential arrangement.

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
saved fingerprint, so the next run tries again. No remote repository repair or
cloud lock deletion is involved. A local `flock` prevents overlapping runs on
this VPS and releases automatically on exit; use a unique `SERVER_ID` on each VPS.

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
It covers extraction, permissions, symlinks, change detection, failed uploads and
readback, retention, overlap protection, and container restart recovery through a
Docker fixture. GitHub Actions runs these checks on Ubuntu 24.04. Cloud-provider
behaviour still needs a disposable fixture upload before adopting a deployment.

MIT license. See [LICENSE](LICENSE).
