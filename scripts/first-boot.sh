#!/bin/bash
# scripts/first-boot.sh — L1 first-boot provisioning umbrella (user_data template).
#
# Rendered by main.tf via templatefile(): scripts/git-pin.sh (issue #2323) and
# scripts/host-hygiene.sh are embedded below as substitution values, so those
# files stay the single source of truth for their engines. This module's
# hygiene variables are exported as HYGIENE_* env vars for the engine.
#
# Idempotent, and user_data is not ForceNew: re-rendering (knob changes) never
# destroys existing servers. On a fresh image it re-provisions everything; on
# an existing VM an operator can re-assert with
#   sudo bash /opt/first-boot.sh        (or the repo bootstrap, see README).
set -euo pipefail

__log() { echo "[$(date -Iseconds)] [first-boot] $1"; }

# ── 1. git pin — embedded engine (single source: scripts/git-pin.sh) ──
GIT_PIN=/opt/git-pin.sh
mkdir -p /opt
cat > "$GIT_PIN.tmp" <<'GIT_PIN_EMBEDDED_EOF'
${git_pin_script}
GIT_PIN_EMBEDDED_EOF
chmod 0755 "$GIT_PIN.tmp"
mv -f "$GIT_PIN.tmp" "$GIT_PIN"
__log "running git pin engine ($GIT_PIN)"
bash "$GIT_PIN" || __log "WARN git pin step failed — see output above (continuing)"

# ── 2. host hygiene — embedded engine (single source: scripts/host-hygiene.sh) ──
HYGIENE_ENGINE=/opt/host-hygiene.sh
cat > "$HYGIENE_ENGINE.tmp" <<'HYGIENE_EMBEDDED_EOF'
${hygiene_script}
HYGIENE_EMBEDDED_EOF
chmod 0755 "$HYGIENE_ENGINE.tmp"
mv -f "$HYGIENE_ENGINE.tmp" "$HYGIENE_ENGINE"

# Module variables -> engine env. Values are rendered by Terraform below;
# hygiene_* are templatefile placeholders, not shell variables.
# shellcheck disable=SC2154
export HYGIENE_JOURNALD_MAX_USE="${hygiene_journald_max_use}"
# shellcheck disable=SC2154
export HYGIENE_DOCKER_PRUNE="${hygiene_docker_prune}"
# shellcheck disable=SC2154
export HYGIENE_DOCKER_PRUNE_UNTIL="${hygiene_docker_prune_until}"
# shellcheck disable=SC2154
export HYGIENE_UNATTENDED_UPGRADES="${hygiene_unattended_upgrades}"
# shellcheck disable=SC2154
export HYGIENE_DISK_ALERT_PCT="${hygiene_disk_alert_pct}"
# shellcheck disable=SC2154
export HYGIENE_DISK_WEBHOOK_URL="${hygiene_disk_webhook_url}"
# shellcheck disable=SC2154
export HYGIENE_SSHD_MAX_STARTUPS="${hygiene_sshd_max_startups}"
# shellcheck disable=SC2154
export HYGIENE_SSHD_MAX_SESSIONS="${hygiene_sshd_max_sessions}"
# shellcheck disable=SC2154
export HYGIENE_SSHD_KEEPALIVE_INTERVAL="${hygiene_sshd_keepalive_interval}"
# shellcheck disable=SC2154
export HYGIENE_SSHD_KEEPALIVE_COUNT="${hygiene_sshd_keepalive_count}"
# shellcheck disable=SC2154
export HYGIENE_SSHD_PERSOURCE_PENALTIES="${hygiene_sshd_persource_penalties}"

# shellcheck disable=SC2154
export HYGIENE_FAIL2BAN_IGNOREIP="${hygiene_fail2ban_ignoreip}"
# shellcheck disable=SC2154
export HYGIENE_FAIL2BAN_REFRESH="${hygiene_fail2ban_refresh}"
# shellcheck disable=SC2154
export HYGIENE_SYSCTL_FORWARDING="${hygiene_sysctl_forwarding}"

# ── 2b. fail2ban ignoreip static fallback data (GitHub Actions ranges) ──
# Data only. host-hygiene.sh section 6 reads this when the live
# api.github.com/meta fetch is unreachable at install/refresh time, so a
# network fault can never strip the sshd jail of its exemptions.
F2B_FALLBACK=/opt/github-actions-cidrs.txt
cat > "$F2B_FALLBACK.tmp" <<'F2B_FALLBACK_EMBEDDED_EOF'
${fail2ban_cidrs_file}
F2B_FALLBACK_EMBEDDED_EOF
chmod 0644 "$F2B_FALLBACK.tmp"
mv -f "$F2B_FALLBACK.tmp" "$F2B_FALLBACK"
__log "deployed fail2ban ignoreip static fallback data ($F2B_FALLBACK)"

__log "running host-hygiene engine (13 knobs from module variables)"
bash "$HYGIENE_ENGINE"