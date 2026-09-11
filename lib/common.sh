#!/usr/bin/env bash
# lib/common.sh — shared logging helpers for the bash-automation library.
#
# Sourced (never executed) by the other scripts in this repo:
#
#   source "$(dirname "$0")/lib/common.sh"
#
# Provides:
#   log_init <logfile>      - start logging to a file (always tee'd to stdout)
#   log <LEVEL> <message>   - timestamped log line, levels INFO/WARN/ERROR/DEBUG
#   die <message> [code]    - log an error and exit non-zero
#   need_cmd <name>         - exit with a clear error if a binary is missing
#   confirm <prompt>        - yes/no prompt, returns 0 on yes
#
# DEBUG lines are only emitted when DEBUG=1 is set in the environment.

set -euo pipefail

# Guard against being sourced twice.
[[ -n "${COMMON_SH_LOADED:-}" ]] && return 0
readonly COMMON_SH_LOADED=1

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
: "${DEBUG:=0}"                # Set DEBUG=1 to enable debug-level lines
: "${COMMON_LOG_TAG:=bash-automation}"

COMMON_LOGFILE=""

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

# Start tee'ing output to a log file. Safe to call multiple times.
log_init() {
    local logfile="$1"
    if [[ -z "$logfile" ]]; then
        die "log_init requires a log file path"
    fi
    local logdir
    logdir="$(dirname "$logfile")"
    mkdir -p "$logdir"
    COMMON_LOGFILE="$logfile"
    # Route all future stdout/stderr through tee while preserving them.
    exec > >(tee -a "$COMMON_LOGFILE") 2>&1
    log "INFO" "Logging started: $COMMON_LOGFILE"
}

# Timestamped log line. Usage: log INFO "message"
log() {
    local level="$1"
    shift
    if [[ "$level" == "DEBUG" && "$DEBUG" != "1" ]]; then
        return 0
    fi
    printf '%s [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" \
        "$COMMON_LOG_TAG" "$*"
}

# Print an error and exit. Usage: die "message" [exit_code]
die() {
    local msg="$1"
    local code="${2:-1}"
    log "ERROR" "$msg"
    exit "$code"
}

# Fail fast with a helpful message if a required command is missing.
need_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "required command not found: $cmd"
    fi
}

# Interactive yes/no prompt. Returns 0 (yes) or 1 (anything else).
confirm() {
    local prompt="$1"
    local answer
    read -r -p "${prompt} [y/N] " answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# Print a section banner into the log for readability.
banner() {
    log "INFO" "--- $* ---"
}
