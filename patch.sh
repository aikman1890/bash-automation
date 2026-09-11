#!/usr/bin/env bash
# patch.sh — OS patching wrapper for yum/dnf (RHEL family) and apt (Debian family).
#
# Modes:
#   --list            Show pending updates, change nothing (default)
#   --apply           Apply updates; ask about reboot unless told otherwise
#   --reboot         With --apply: reboot afterwards without prompting
#   --no-reboot      With --apply: never reboot
#
# Examples:
#   sudo ./patch.sh --list
#   sudo ./patch.sh --apply --no-reboot
#   sudo ./patch.sh --apply --reboot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: patch.sh [options]

OS package patching wrapper: detects dnf/yum or apt, refreshes metadata,
lists pending updates, and optionally applies them.

  --list         Show pending updates and exit (default, no changes)
  --apply        Apply all pending updates
  --reboot       After --apply: reboot automatically (no prompt)
  --no-reboot    After --apply: never reboot
  -h, --help     Show this help and exit

With --apply and neither reboot flag, a reboot is offered interactively.
EOF
}

# ----------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------
MODE="list"
REBOOT_POLICY="ask"   # ask | yes | no

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)     MODE="list" ;;
        --apply)    MODE="apply" ;;
        --reboot)   REBOOT_POLICY="yes" ;;
        --no-reboot) REBOOT_POLICY="no" ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown option: $1 (see -h/--help)" ;;
    esac
    shift
done

# ----------------------------------------------------------------------------
# Detect package manager
# ----------------------------------------------------------------------------
if command -v dnf >/dev/null 2>&1; then
    PM="dnf"
elif command -v yum >/dev/null 2>&1; then
    PM="yum"
elif command -v apt-get >/dev/null 2>&1; then
    PM="apt"
else
    die "no supported package manager found (dnf/yum/apt)"
fi

log_init "/var/log/patch-$(date '+%Y%m%d-%H%M%S').log"
banner "patch.sh ($MODE mode)"
log "INFO" "Package manager detected: $PM"

# ----------------------------------------------------------------------------
# Refresh metadata and list pending updates
# ----------------------------------------------------------------------------
if [[ "$PM" == "apt" ]]; then
    log "INFO" "Running: apt-get update"
    apt-get update
    log "INFO" "Pending updates:"
    apt list --upgradable 2>/dev/null | tail -n +2
    PENDING_COUNT="$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)"
else
    log "INFO" "Running: $PM makecache"
    "$PM" makecache -y
    log "INFO" "Pending updates:"
    "$PM" check-update || true   # exits 100 when updates exist — that's fine
    PENDING_COUNT="$("$PM" check-update -q | grep -cv 'Obsoleting\|^$' || true)"
fi

log "INFO" "Pending update count: $PENDING_COUNT"

if [[ "$MODE" == "list" ]]; then
    log "INFO" "List mode complete — no changes made."
    exit 0
fi

if [[ "$PENDING_COUNT" -eq 0 ]]; then
    log "INFO" "Nothing to apply — system is up to date."
    exit 0
fi

# ----------------------------------------------------------------------------
# Apply updates
# ----------------------------------------------------------------------------
if ! confirm "Apply $PENDING_COUNT update(s) now?"; then
    log "INFO" "Aborted by operator."
    exit 0
fi

banner "Applying updates"
if [[ "$PM" == "apt" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
else
    "$PM" -y update
fi
log "INFO" "Package updates applied successfully."

# ----------------------------------------------------------------------------
# Reboot handling
# ----------------------------------------------------------------------------
case "$REBOOT_POLICY" in
    yes)
        log "INFO" "Reboot flag set — rebooting now."
        shutdown -r now "patch.sh: reboot after updates"
        ;;
    no)
        log "INFO" "Reboot suppressed by --no-reboot."
        ;;
    ask)
        if confirm "Updates applied. Reboot now?"; then
            log "INFO" "Rebooting at operator request."
            shutdown -r now "patch.sh: reboot after updates"
        else
            log "WARN" "Reboot declined — a reboot may still be required for kernel/library updates."
        fi
        ;;
esac

log "INFO" "patch.sh finished."
