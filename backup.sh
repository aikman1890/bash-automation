#!/usr/bin/env bash
# backup.sh — rsync-based system backup with rotation, excludes, and logging.
#
# Each run creates a timestamped snapshot under the destination directory and
# refreshes a `latest` symlink. Snapshots older than the retention count are
# removed. All output is logged via lib/common.sh.
#
# Example:
#   sudo ./backup.sh -s /data -d /mnt/backups/db1 -k 7

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: backup.sh -s SRC -d DEST [options]

Create a timestamped rsync snapshot of SRC inside DEST.

Required:
  -s SRC     Source directory to back up
  -d DEST    Destination directory holding snapshots

Options:
  -k KEEP    Snapshots to retain (default: 7)
  -e PAT     Extra rsync --exclude pattern (repeatable)
  -n         Dry run: show what would happen, change nothing
  -h         Show this help and exit

The destination gets a new directory named YYYYmmdd-HHMMSS and a `latest`
symlink pointing at it. Snapshots beyond -k are deleted oldest-first.
EOF
}

# ----------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------
SRC=""
DEST=""
KEEP=7
DRY_RUN=0
EXTRA_EXCLUDES=()

while getopts ":s:d:k:e:nh" opt; do
    case "$opt" in
        s) SRC="$OPTARG" ;;
        d) DEST="$OPTARG" ;;
        k) KEEP="$OPTARG" ;;
        e) EXTRA_EXCLUDES+=("$OPTARG") ;;
        n) DRY_RUN=1 ;;
        h) usage; exit 0 ;;
        :) die "option -$OPTARG requires an argument (see -h)" ;;
        \?) die "unknown option: -$OPTARG (see -h)" ;;
    esac
done

[[ -n "$SRC" ]]  || die "source directory is required (-s)"
[[ -n "$DEST" ]] || die "destination directory is required (-d)"
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || die "-k must be a positive integer"

need_cmd rsync

[[ -d "$SRC" ]] || die "source directory does not exist: $SRC"
mkdir -p "$DEST"

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
LOG_DIR="${DEST}/.backup-logs"
mkdir -p "$LOG_DIR"
log_init "${LOG_DIR}/backup-$(date '+%Y%m%d-%H%M%S').log"

# ----------------------------------------------------------------------------
# Build the rsync command
# ----------------------------------------------------------------------------
DEFAULT_EXCLUDES=(
    'proc'
    'sys'
    'dev'
    'tmp'
    'var/tmp'
    '*~'
    '.cache'
    '.Trash*'
)

RSYNC_OPTS=( -aH --delete --numeric-ids )
if [[ "$DRY_RUN" -eq 1 ]]; then
    RSYNC_OPTS+=( --dry-run )
    log "INFO" "DRY RUN enabled — nothing will be written"
fi

for pat in "${DEFAULT_EXCLUDES[@]}" "${EXTRA_EXCLUDES[@]}"; do
    RSYNC_OPTS+=( --exclude="$pat" )
done

SNAP="${DEST}/$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$SNAP"

banner "Backup started"
log "INFO" "Source:      $SRC"
log "INFO" "Snapshot:    $SNAP"
log "INFO" "Keep:        $KEEP snapshot(s)"
log "INFO" "Excludes:    ${DEFAULT_EXCLUDES[*]} ${EXTRA_EXCLUDES[*]:-}"

START_TS="$(date +%s)"
if rsync "${RSYNC_OPTS[@]}" "${SRC}/" "${SNAP}/"; then
    log "INFO" "rsync completed successfully"
else
    rc=$?
    log "ERROR" "rsync failed with exit code $rc — removing incomplete snapshot"
    rm -rf "$SNAP"
    exit "$rc"
fi
log "INFO" "Backup duration: $(( $(date +%s) - START_TS ))s"

# ----------------------------------------------------------------------------
# Refresh the `latest` symlink and enforce rotation
# ----------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 0 ]]; then
    ln -sfn "$(basename "$SNAP")" "${DEST}/latest"
    log "INFO" "Updated 'latest' symlink -> $(basename "$SNAP")"
fi

mapfile -t SNAPSHOTS < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d \
    -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' \
    | sort)
PRUNE_COUNT=$(( ${#SNAPSHOTS[@]} - KEEP ))
if [[ "$PRUNE_COUNT" -gt 0 ]]; then
    log "INFO" "Pruning $PRUNE_COUNT old snapshot(s)"
    for (( i=0; i<PRUNE_COUNT; i++ )); do
        log "INFO" "Removing ${SNAPSHOTS[$i]}"
        if [[ "$DRY_RUN" -eq 0 ]]; then
            rm -rf "${SNAPSHOTS[$i]}"
        fi
    done
else
    log "INFO" "No snapshots to prune (${#SNAPSHOTS[@]} present, keeping $KEEP)"
fi

banner "Backup finished"
log "INFO" "Snapshot retained at: $SNAP"
