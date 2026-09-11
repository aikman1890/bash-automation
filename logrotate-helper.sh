#!/usr/bin/env bash
# logrotate-helper.sh — rotate app logs by size and/or age, gzip, and prune.
#
# Scans a directory for *.log files. A file is rotated when it is at least
# --max-size in size OR older than --max-days. Rotated files are compressed
# with gzip; only --keep archives per base name are retained.
#
# Example:
#   sudo ./logrotate-helper.sh -d /var/log/myapp -s 100M -a 30 -k 14

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: logrotate-helper.sh -d DIR [options]

Rotate *.log files in DIR when they reach a size or age threshold.

Required:
  -d DIR     Log directory to scan

Options:
  -s SIZE    Rotate files at or above SIZE, e.g. 100M, 1G (default: 100M)
  -a DAYS    Also rotate files older than DAYS (default: 30)
  -k KEEP    Compressed archives to keep per log file (default: 14)
  -n         Dry run: show what would happen, change nothing
  -h         Show this help and exit
EOF
}

# ----------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------
LOG_DIR=""
MAX_SIZE="100M"
MAX_DAYS=30
KEEP=14
DRY_RUN=0

while getopts ":d:s:a:k:nh" opt; do
    case "$opt" in
        d) LOG_DIR="$OPTARG" ;;
        s) MAX_SIZE="$OPTARG" ;;
        a) MAX_DAYS="$OPTARG" ;;
        k) KEEP="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        h) usage; exit 0 ;;
        :) die "option -$OPTARG requires an argument (see -h)" ;;
        \?) die "unknown option: -$OPTARG (see -h)" ;;
    esac
done

[[ -n "$LOG_DIR" ]] || die "log directory is required (-d)"
[[ -d "$LOG_DIR" ]] || die "log directory does not exist: $LOG_DIR"
[[ "$MAX_SIZE" =~ ^[0-9]+[KMG]?$ ]] || die "-s must look like 100M, 1G, or bytes"
[[ "$MAX_DAYS" =~ ^[0-9]+$ ]] || die "-a must be a number of days"
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || die "-k must be a positive integer"

need_cmd gzip

log_init "${LOG_DIR}/.logrotate-helper.log"

banner "logrotate-helper started"
log "INFO" "Directory:  $LOG_DIR"
log "INFO" "Max size:   $MAX_SIZE"
log "INFO" "Max age:    ${MAX_DAYS}d"
log "INFO" "Keep:       $KEEP archive(s) per log"
[[ "$DRY_RUN" -eq 1 ]] && log "INFO" "DRY RUN enabled — nothing will be written"

ROTATED=0
PRUNED=0

shopt -s nullglob
for logfile in "$LOG_DIR"/*.log; do
    base="$(basename "$logfile")"

    # --- size test: does the file reach the threshold? ----------------------
    size_bytes="$(stat -c %s "$logfile")"
    case "$MAX_SIZE" in
        *G) threshold=$(( ${MAX_SIZE%G} * 1024 * 1024 * 1024 )) ;;
        *M) threshold=$(( ${MAX_SIZE%M} * 1024 * 1024 )) ;;
        *K) threshold=$(( ${MAX_SIZE%K} * 1024 )) ;;
        *)  threshold="$MAX_SIZE" ;;
    esac

    # --- age test: is the file older than MAX_DAYS? -------------------------
    old_enough=0
    if [[ -n "$(find "$logfile" -mtime +"$MAX_DAYS" -print 2>/dev/null)" ]]; then
        old_enough=1
    fi

    if [[ "$size_bytes" -lt "$threshold" && "$old_enough" -eq 0 ]]; then
        log "INFO" "SKIP: $base (${size_bytes} bytes, within limits)"
        continue
    fi

    reason="size ${size_bytes} >= ${threshold}"
    [[ "$old_enough" -eq 1 ]] && reason="${reason}; older than ${MAX_DAYS}d"
    log "INFO" "ROTATE: $base ($reason)"

    stamp="$(date '+%Y%m%d-%H%M%S')"
    archive="${LOG_DIR}/${base}.${stamp}.gz"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "INFO" "(dry run) would compress $base -> $(basename "$archive") and truncate original"
        ROTATED=$(( ROTATED + 1 ))
        continue
    fi

    gzip -c "$logfile" > "$archive"
    : > "$logfile"    # truncate in place so running processes keep their fd
    ROTATED=$(( ROTATED + 1 ))
    log "INFO" "Wrote $(basename "$archive") and truncated $base"

    # --- prune old archives beyond --keep ------------------------------------
    mapfile -t archives < <(ls -t "${LOG_DIR}/${base}."*.gz 2>/dev/null)
    if [[ "${#archives[@]}" -gt "$KEEP" ]]; then
        for (( i=KEEP; i<${#archives[@]}; i++ )); do
            log "INFO" "PRUNE: $(basename "${archives[$i]}")"
            rm -f "${archives[$i]}"
            PRUNED=$(( PRUNED + 1 ))
        done
    fi
done
shopt -u nullglob

banner "logrotate-helper finished"
log "INFO" "Rotated: $ROTATED file(s), pruned: $PRUNED archive(s)"
