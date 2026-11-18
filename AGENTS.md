# Working in this repository

Runtime code is Bash for Ubuntu. Keep the public entry point in `backup.sh`,
configuration/cloud helpers in `lib/common.sh`, and the backup lifecycle in
`lib/backup.sh`. Do not add services, installers, daemons or language runtimes.
Dependencies are external command-line tools installed by the Ubuntu bootstrap.

Use explicit status checks for expected failures. Avoid calling a multi-step
operation in an `if`, `!`, or `&&`/`||` chain: Bash suppresses errexit throughout
that function. Keep `pipefail`, inherited errexit and JSON/stdout separation.
The EXIT trap owns scratch cleanup and recovery of containers stopped by this run.
Do not delete a failed restart journal or commit a fingerprint before the selected verification (full readback by default,
remote size with --skip-hash-check).

Cloud configuration must stay in memory. Never add credentials to examples,
fixtures, logs or commits. Existing private `.env` and `rclone.conf` files are
operator data, not inputs to the replacement. Do not deploy without authorization.

Run shellcheck, `bash tests/backup.sh`, and the notification tests in the README.
Tests must use disposable local storage and fake Docker, not running containers.
Keep ordinary setup and operation in the README; avoid adding a documentation
tree for a tool this size. Preserve independent Discord/Telegram toggles.
