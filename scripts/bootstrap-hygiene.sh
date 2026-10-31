#!/bin/bash
# scripts/bootstrap-hygiene.sh — idempotent host-hygiene bootstrap for
# ALREADY-PROVISIONED VMs (the ~2-minute path for existing hosts).
#
# Applies ALL generic host-hygiene bounds the L1 module provisions on new
# VMs — journald cap, docker-prune timer, unattended security upgrades,
# disk-watch alarm, sshd connection bounds — by running the shared engine
# scripts/host-hygiene.sh from this checkout. Dry-run by default; pass
# --apply to install, or --check for a read-only drift report. Safe:
# installs only, never deletes anything by hand.
#
# Usage (on the target VM, from the L1 checkout):
#   sudo bash scripts/bootstrap-hygiene.sh               # dry run (default)
#   sudo bash scripts/bootstrap-hygiene.sh --apply       # install (idempotent)
#   bash scripts/bootstrap-hygiene.sh --check            # read-only drift report (no root)
#
# Knobs are HYGIENE_* env vars with the same defaults as the module variables:
#   HYGIENE_JOURNALD_MAX_USE      journald SystemMaxUse cap (default 1G)
#   HYGIENE_DOCKER_PRUNE          true|false — docker-prune timer (default true)
#   HYGIENE_DOCKER_PRUNE_UNTIL    docker prune until= filter  (default 168h)
#   HYGIENE_UNATTENDED_UPGRADES   true|false — security auto-upgrades (default true)
#   HYGIENE_DISK_ALERT_PCT        root-used % alarm threshold; 0 disables (default 85)
#   HYGIENE_DISK_WEBHOOK_URL      webhook for alarm POSTs; empty = off (default off)
#   HYGIENE_SSHD_MAX_STARTUPS     sshd MaxStartups triple  (default 40:30:100); 0/empty = don't manage sshd
#   HYGIENE_SSHD_MAX_SESSIONS     sshd MaxSessions (default 20)
#   HYGIENE_SSHD_KEEPALIVE_INTERVAL  sshd ClientAliveInterval seconds (default 60)
#   HYGIENE_SSHD_KEEPALIVE_COUNT  sshd ClientAliveCountMax (default 3)
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: sudo bash scripts/bootstrap-hygiene.sh [--apply|--check]

  Dry-run by default: prints what would be installed, changes nothing.
  --apply: installs all host-hygiene items. Idempotent — safe to re-run.
  --check: read-only drift report — renders every managed artifact into a
    temp dir and compares it with the live host (no root required). Exit
    codes: 0 = clean, 1 = drift, 2 = cannot evaluate.

  Per-run knob overrides (all optional, defaults match the module variables):
    HYGIENE_JOURNALD_MAX_USE=1G HYGIENE_DOCKER_PRUNE=true
    HYGIENE_DOCKER_PRUNE_UNTIL=168h HYGIENE_UNATTENDED_UPGRADES=true
    HYGIENE_DISK_ALERT_PCT=85 HYGIENE_DISK_WEBHOOK_URL=https://...
    HYGIENE_SSHD_MAX_STARTUPS=40:30:100 HYGIENE_SSHD_MAX_SESSIONS=20
    HYGIENE_SSHD_KEEPALIVE_INTERVAL=60 HYGIENE_SSHD_KEEPALIVE_COUNT=3
EOF
}

APPLY=0
CHECK=0
for arg in "$@"; do
	case "$arg" in
		--apply) APPLY=1 ;;
		--check) CHECK=1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
	esac
done
if [ "$APPLY" = 1 ] && [ "$CHECK" = 1 ]; then
	echo "cannot combine --apply and --check" >&2
	usage >&2
	exit 2
fi

# --check is read-only and needs no root; apply/dry-run still do.
if [ "$CHECK" = 0 ] && [ "$(id -u)" -ne 0 ]; then
	echo "bootstrap-hygiene.sh must run as root (sudo) unless --check is used." >&2
	exit 1
fi

ENGINE_DIR=$(cd "$(dirname "$0")" && pwd)
ENGINE="$ENGINE_DIR/host-hygiene.sh"
if [ ! -f "$ENGINE" ]; then
	echo "host-hygiene.sh not found next to bootstrap-hygiene.sh (expected at: $ENGINE)" >&2
	exit 1
fi

if [ "$CHECK" = 1 ]; then
	echo "== host-hygiene bootstrap: CHECK (read-only drift report; engine: $ENGINE) =="
	bash "$ENGINE" --check
	echo "== check complete — 0 = clean, 1 = drift, 2 = cannot evaluate =="
elif [ "$APPLY" = 1 ]; then
	echo "== host-hygiene bootstrap: APPLYING (engine: $ENGINE) =="
	bash "$ENGINE"
	echo "== bootstrap complete — installed items are logged above. Re-run anytime (idempotent). =="
else
	echo "== host-hygiene bootstrap: DRY RUN (no changes; pass --apply to install) =="
	HYGIENE_DRY_RUN=1 bash "$ENGINE"
	echo "== dry run complete — nothing was changed. Pass --apply to install. =="
fi
