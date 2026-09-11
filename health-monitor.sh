#!/usr/bin/env bash
# health-monitor.sh — check services, TCP ports, and disk usage; alert on failure.
#
# On any failed check, send_alert() POSTs a JSON payload to the webhook URL in
# the ALERT_WEBHOOK environment variable. If ALERT_WEBHOOK is unset, alerts are
# written to the log only (no external call is made).
#
# Example:
#   export ALERT_WEBHOOK="https://hooks.example.com/sre-alerts"
#   sudo ./health-monitor.sh -s sshd,nginx -p 80,443 -d 85

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: health-monitor.sh [options]

Check that services are running, TCP ports are listening, and no filesystem
exceeds a disk-usage threshold. Exit 0 if all checks pass, 1 otherwise.

Options:
  -s LIST   Comma-separated service names (default: sshd)
  -p LIST   Comma-separated TCP ports to check listening (default: 22)
  -d PCT    Disk-usage alert threshold percent (default: 85)
  -h        Show this help and exit

Environment:
  ALERT_WEBHOOK   URL to POST alert JSON to on failure (optional)
  HOSTNAME_OVERRIDE  Used in alert payloads when hostname is unreliable
EOF
}

# ----------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------
SERVICES="sshd"
PORTS="22"
DISK_THRESHOLD=85

while getopts ":s:p:d:h" opt; do
    case "$opt" in
        s) SERVICES="$OPTARG" ;;
        p) PORTS="$OPTARG" ;;
        d) DISK_THRESHOLD="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) die "option -$OPTARG requires an argument (see -h)" ;;
        \?) die "unknown option: -$OPTARG (see -h)" ;;
    esac
done

[[ "$DISK_THRESHOLD" =~ ^[0-9]+$ && "$DISK_THRESHOLD" -le 100 ]] \
    || die "-d must be a percentage between 0 and 100"

need_cmd systemctl
need_cmd ss
need_cmd df

# ----------------------------------------------------------------------------
# Logging + alert hook
# ----------------------------------------------------------------------------
log_init "/var/log/health-monitor-$(date '+%Y%m%d-%H%M%S').log"

HOST_LABEL="${HOSTNAME_OVERRIDE:-$(hostname -f 2>/dev/null || hostname)}"

# POST a failure to the webhook, or log-only when ALERT_WEBHOOK is unset.
send_alert() {
    local check_name="$1"
    local detail="$2"
    local payload
    payload="$(printf '{"host":%s,"check":%s,"detail":%s,"time":"%s","severity":"critical"}' \
        "$(printf '%s' "$HOST_LABEL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        "$(printf '%s' "$check_name" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        "$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"

    if [[ -n "${ALERT_WEBHOOK:-}" ]]; then
        need_cmd curl
        if curl -fsS -m 15 -X POST -H 'Content-Type: application/json' \
                -d "$payload" "$ALERT_WEBHOOK" >/dev/null; then
            log "INFO" "Alert delivered to webhook for: $check_name"
        else
            log "ERROR" "Failed to POST alert for: $check_name"
        fi
    else
        log "WARN" "ALERT_WEBHOOK unset — alert logged only: [$check_name] $detail"
    fi
}

FAILURES=0
record_failure() {
    FAILURES=$(( FAILURES + 1 ))
    log "ERROR" "FAIL: $1 — $2"
    send_alert "$1" "$2"
}

banner "Health check started on $HOST_LABEL"

# ----------------------------------------------------------------------------
# Service checks
# ----------------------------------------------------------------------------
banner "Service checks"
IFS=',' read -ra SVC_LIST <<< "$SERVICES"
for svc in "${SVC_LIST[@]}"; do
    svc="$(printf '%s' "$svc" | tr -d '[:space:]')"
    [[ -z "$svc" ]] && continue
    if systemctl is-active --quiet "$svc"; then
        log "INFO" "PASS: service $svc is active"
    else
        record_failure "service:$svc" "service $svc is not active"
    fi
done

# ----------------------------------------------------------------------------
# Port checks (listening sockets)
# ----------------------------------------------------------------------------
banner "Port checks"
IFS=',' read -ra PORT_LIST <<< "$PORTS"
for port in "${PORT_LIST[@]}"; do
    port="$(printf '%s' "$port" | tr -d '[:space:]')"
    [[ -z "$port" ]] && continue
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}\$"; then
        log "INFO" "PASS: TCP port $port is listening"
    else
        record_failure "port:$port" "TCP port $port is not listening"
    fi
done

# ----------------------------------------------------------------------------
# Disk usage checks (skip pseudo-filesystems)
# ----------------------------------------------------------------------------
banner "Disk checks (threshold ${DISK_THRESHOLD}%)"
while IFS= read -r line; do
    pct="${line%% *}"
    mnt="${line#* }"
    pct_num="${pct%\%}"
    if [[ "$pct_num" -ge "$DISK_THRESHOLD" ]]; then
        record_failure "disk:$mnt" "filesystem $mnt is at $pct (threshold ${DISK_THRESHOLD}%)"
    else
        log "INFO" "PASS: $mnt at $pct"
    fi
done < <(df -P -x tmpfs -x devtmpfs -x overlay 2>/dev/null \
          | awk 'NR>1 {print $5" "$6}')

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
if [[ "$FAILURES" -eq 0 ]]; then
    log "INFO" "All health checks passed."
    exit 0
else
    log "ERROR" "$FAILURES check(s) failed."
    exit 1
fi
