# bash-automation

A small library of production-hardened Bash scripts I use for day-to-day Linux
operations: backups, OS patching, health monitoring, and log rotation. Every
script follows the same conventions:

- `#!/usr/bin/env bash` shebang
- `set -euo pipefail` for strict mode
- A `usage()` help function and `getopts`-style options where sensible
- Shared logging helpers sourced from `lib/common.sh`
- All output timestamped and written to a log file, not just the console

Tested on RHEL 8/9, CentOS Stream 9, and Ubuntu 22.04/24.04.

## Requirements

- Bash 4.2+
- `rsync` (backup.sh)
- `curl` (health-monitor.sh, only if `ALERT_WEBHOOK` is set)
- Root or sudo for `patch.sh` (package management) and `health-monitor.sh`
  (service status checks)

## Layout

```text
bash-automation/
├── README.md
├── LICENSE
├── lib/
│   └── common.sh            # Shared logging/helpers; sourced by all scripts
├── backup.sh                # rsync system backup with rotation and logging
├── patch.sh                 # yum/dnf + apt wrapper: update, list, apply, reboot
├── health-monitor.sh        # Service/port/disk checks with webhook alert hook
└── logrotate-helper.sh      # Size/age-based rotation of app logs
```

## Usage

Source the common library at the top of each script:

```bash
source "$(dirname "$0")/lib/common.sh"
```

### backup.sh

Back up a source tree to a destination directory with daily rotation, a list of
exclude patterns, and a persistent log.

```bash
sudo ./backup.sh -s /data -d /mnt/backups/host1 -k 7
```

Options:

| Flag | Meaning |
|------|---------|
| `-s` | Source directory (required) |
| `-d` | Backup destination directory (required) |
| `-k` | Snapshots to keep (default: `7`) |
| `-e` | Extra rsync exclude pattern (repeatable) |
| `-n` | Dry run — print what would happen, change nothing |
| `-h` | Show help |

Each run creates a timestamped snapshot (`YYYYmmdd-HHMMSS`) and symlinks
`latest` to the most recent one. Older snapshots beyond `-k` are deleted.
Default excludes: `proc sys dev tmp /var/tmp cache *~ .cache`.

### patch.sh

Wrapper around `dnf`/`yum`/`apt`: refreshes the package metadata, lists pending
updates, applies them, and logs everything.

```bash
# List what is pending (no changes)
sudo ./patch.sh --list

# Apply updates, skip reboot prompt
sudo ./patch.sh --apply --no-reboot

# Apply updates and reboot afterwards (RHEL only if kernel changed)
sudo ./patch.sh --apply --reboot
```

By default `--apply` asks for confirmation before rebooting; `--reboot`
skips the prompt and `--no-reboot` never reboots.

### health-monitor.sh

Checks that required services are running, required TCP ports are listening,
and disk usage is under a threshold. On any failure it calls `send_alert()`,
which POSTs JSON to the webhook URL in `ALERT_WEBHOOK` (unset = log only).

```bash
export ALERT_WEBHOOK="https://hooks.example.com/sre-alerts"
sudo ./health-monitor.sh -s sshd,nginx -p 80,443 -d 85
```

Options:

| Flag | Meaning |
|------|---------|
| `-s` | Comma-separated service names to check (default: `sshd`) |
| `-p` | Comma-separated TCP ports to check (default: `22`) |
| `-d` | Disk-usage alert threshold in percent (default: `85`) |
| `-h` | Show help |

Exit code is `0` when everything passes, `1` when any check fails.

### logrotate-helper.sh

Rotates application logs that grow without a packaged logrotate rule: files
larger than `--max-size` or older than `--max-days` are compressed with gzip,
and archives beyond `--keep` are pruned.

```bash
sudo ./logrotate-helper.sh -d /var/log/myapp -s 100M -k 14 -a 30
```

Options:

| Flag | Meaning |
|------|---------|
| `-d` | Log directory to scan (required) |
| `-s` | Rotate files at or above this size, e.g. `100M` (default: `100M`) |
| `-a` | Also rotate files older than this many days (default: `30`) |
| `-k` | Compressed archives to keep per log (default: `14`) |
| `-n` | Dry run |
| `-h` | Show help |

## License

MIT — see [LICENSE](LICENSE).
