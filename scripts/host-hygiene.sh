#!/bin/bash
# scripts/host-hygiene.sh — L1 generic host-hygiene provisioning engine.
#
# Ships GENERIC, workload-agnostic bounds to a Linux VM:
#   1. journald cap            — /etc/systemd/journald.conf.d/90-host-hygiene.conf
#   2. docker-prune timer      — /etc/systemd/system/docker-prune.{service,timer}
#   3. unattended security-only auto-upgrades (no auto-reboot)
#                                                   — /etc/apt/apt.conf.d/52host-hygiene-*
#   4. generic disk-watch alarm — systemd weekly timer + /usr/local/bin watchdog
#   5. sshd connection bounds  — /etc/ssh/sshd_config.d/09-sshd-limits.conf
#
# Deliberately NOT here (layering): workload-specific retention (capture
# pruner, disk-warden, growth report) lives in linux-desktop-seed at user
# scope. L1 ships generic bounds only, so this is safe on any workload.
#
# This engine is the shared implementation for BOTH entry points:
#   - provision time: scripts/first-boot.sh (user_data template) exports this
#     module's Terraform variables as HYGIENE_* env vars and runs the engine;
#   - existing VMs:   scripts/bootstrap-hygiene.sh runs the same engine
#     (dry-run by default, --apply installs).
#
# Configuration comes from HYGIENE_* environment variables with the module's
# defaults below, so the engine is valid standalone. Idempotent: safe to
# re-run any time. Installs only — never deletes anything by hand.
# HYGIENE_DRY_RUN=1 prints what would change without touching the system.
set -eo pipefail

SELF_COPY=/opt/host-hygiene.sh

# ── Minimal helpers (self-contained — L1 module owns this, no lib.sh) ──
__log() { echo "[$(date -Iseconds)] [$1] $2"; }
info()  { __log "INFO"  "$1"; }
warn()  { __log "WARN"  "$1"; }
error() { __log "ERROR" "$1"; }

package_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

apt_install() {
	local pkg="$1"
	if package_installed "$pkg"; then
		info "package already installed: $pkg"
		return 0
	fi
	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would install package $pkg"
		return 0
	fi
	info "installing: $pkg"
	apt-get install -y --no-install-recommends "$pkg" || {
		# Fresh images may have stale/absent package lists; refresh and retry.
		info "apt-get update + retry install for $pkg"
		apt-get update -qq
		apt-get install -y --no-install-recommends "$pkg"
	}
}

is_systemd() {
	[ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]
}

# systemctl wrapper that respects dry-run mode and skips cleanly when PID 1
# is not systemd (chroot/container), so the engine never hard-fails there.
systemctl_apply() {
	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would run: systemctl $*"
		return 0
	fi
	if ! is_systemd; then
		warn "PID 1 is not systemd — skipped: systemctl $*"
		return 0
	fi
	systemctl "$@"
}

# ── Configuration (HYGIENE_* env overrides; defaults match module vars) ──
: "${HYGIENE_JOURNALD_MAX_USE:=1G}"
: "${HYGIENE_DOCKER_PRUNE:=true}"
: "${HYGIENE_DOCKER_PRUNE_UNTIL:=168h}"
: "${HYGIENE_UNATTENDED_UPGRADES:=true}"
: "${HYGIENE_DISK_ALERT_PCT:=85}"
: "${HYGIENE_SSHD_MAX_SESSIONS:=20}"
: "${HYGIENE_SSHD_KEEPALIVE_INTERVAL:=60}"
: "${HYGIENE_SSHD_KEEPALIVE_COUNT:=3}"
# HYGIENE_SSHD_MAX_STARTUPS (the sshd-bounds gate) is deliberately NOT
# defaulted here: `0` or an explicitly empty value opts out of sshd
# management entirely; unset falls back to the module default 40:30:100
# inside section 5.
# HYGIENE_DISK_WEBHOOK_URL is optional; empty/absent = webhook off.

# ── Persist a canonical copy for operator re-runs (mirrors git-pin.sh) ──
if [ -z "$HYGIENE_DRY_RUN" ] && [ "$(readlink -f "$0")" != "$SELF_COPY" ]; then
	mkdir -p "$(dirname "$SELF_COPY")"
	cp "$0" "$SELF_COPY.tmp"
	chmod 0755 "$SELF_COPY.tmp"
	mv "$SELF_COPY.tmp" "$SELF_COPY"
	info "saved canonical engine to $SELF_COPY (re-run: sudo bash $SELF_COPY)"
fi

# ═══════════════════════════════════════════════════════════════════════
# 1. journald cap
# ═══════════════════════════════════════════════════════════════════════
JOURNALD_DROP_IN=/etc/systemd/journald.conf.d/90-host-hygiene.conf
info "journald: cap SystemMaxUse=$HYGIENE_JOURNALD_MAX_USE"
if [ -n "$HYGIENE_DRY_RUN" ]; then
	info "DRY RUN: would write $JOURNALD_DROP_IN and restart systemd-journald"
else
	mkdir -p "$(dirname "$JOURNALD_DROP_IN")"
	printf '[Journal]\nSystemMaxUse=%s\n' "$HYGIENE_JOURNALD_MAX_USE" > "$JOURNALD_DROP_IN.tmp"
	mv -f "$JOURNALD_DROP_IN.tmp" "$JOURNALD_DROP_IN"
	info "journald cap written: SystemMaxUse=$HYGIENE_JOURNALD_MAX_USE ($JOURNALD_DROP_IN)"
fi
if is_systemd; then
	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would restart systemd-journald"
	else
		systemctl restart systemd-journald
		info "restarted systemd-journald (cap active)"
	fi
else
	warn "PID 1 is not systemd — journald restart skipped (drop-in still written)"
fi

# ═══════════════════════════════════════════════════════════════════════
# 2. docker-prune timer (var-gated; skips cleanly without docker)
# ═══════════════════════════════════════════════════════════════════════
info "docker-prune: gate=$HYGIENE_DOCKER_PRUNE"
DOCKER_BIN=$(command -v docker 2>/dev/null || true)
if [ -z "$DOCKER_BIN" ]; then
	warn "docker not installed — docker-prune timer skipped (nothing to prune)"
elif [ "$HYGIENE_DOCKER_PRUNE" != "true" ]; then
	warn "docker-prune disabled by HYGIENE_DOCKER_PRUNE=$HYGIENE_DOCKER_PRUNE — skipping"
	if is_systemd && [ -f /etc/systemd/system/docker-prune.timer ]; then
		systemctl_apply disable --now docker-prune.timer 2>/dev/null || true
		info "docker-prune timer disabled (unit files left in place; re-enable: HYGIENE_DOCKER_PRUNE=true re-run)"
	fi
else
	SERVICE=/etc/systemd/system/docker-prune.service
	TIMER=/etc/systemd/system/docker-prune.timer
	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would install $SERVICE + $TIMER (prune all --filter until=$HYGIENE_DOCKER_PRUNE_UNTIL) and enable docker-prune.timer"
	else
		mkdir -p /etc/systemd/system
		cat > "$SERVICE.tmp" <<EOF
[Unit]
Description=Host-hygiene docker prune (weekly)
Documentation=https://docs.docker.com/engine/reference/commandline/system_prune/

[Service]
Type=oneshot
# Generic bounds only: no -a (keep all images), volumes are NEVER pruned
# (volume prune is destructive and workload-specific).
ExecStart=$DOCKER_BIN system prune -f --filter "until=$HYGIENE_DOCKER_PRUNE_UNTIL"
Nice=10
IOSchedulingClass=Idle
EOF
		mv -f "$SERVICE.tmp" "$SERVICE"
		cat > "$TIMER.tmp" <<'EOF'
[Unit]
Description=Weekly host-hygiene docker prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
		mv -f "$TIMER.tmp" "$TIMER"
		systemctl_apply daemon-reload
		systemctl_apply enable --now docker-prune.timer
		info "docker-prune timer installed and enabled (until=$HYGIENE_DOCKER_PRUNE_UNTIL)"
	fi
fi

# ═══════════════════════════════════════════════════════════════════════
# 3. unattended security-only auto-upgrades (no auto-reboot)
# ═══════════════════════════════════════════════════════════════════════
info "unattended-upgrades: gate=$HYGIENE_UNATTENDED_UPGRADES"
if [ "$HYGIENE_UNATTENDED_UPGRADES" != "true" ]; then
	warn "unattended-upgrades disabled — skipping (previously written apt fragments stay active)"
else
	apt_install unattended-upgrades
	AUTO_CONF=/etc/apt/apt.conf.d/52host-hygiene-auto-upgrades
	UNATT_CONF=/etc/apt/apt.conf.d/52host-hygiene-unattended
	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would write $AUTO_CONF and $UNATT_CONF (security-only origins, no auto-reboot)"
	else
		mkdir -p /etc/apt/apt.conf.d
		cat > "$AUTO_CONF.tmp" <<'EOF'
// Host hygiene (L1, generic): daily apt-lists refresh + unattended-upgrades.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
		mv -f "$AUTO_CONF.tmp" "$AUTO_CONF"
		cat > "$UNATT_CONF.tmp" <<'EOF'
// Host hygiene (L1, generic): SECURITY-ONLY automatic upgrades, no reboot.
// ${distro_id}/${distro_codename} are expanded by apt, not by this script.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF
		mv -f "$UNATT_CONF.tmp" "$UNATT_CONF"
		info "unattended-upgrades configured: security-only origins, no auto-reboot ($AUTO_CONF, $UNATT_CONF)"
	fi
fi

# ═══════════════════════════════════════════════════════════════════════
# 4. generic disk-watch alarm (weekly; loud journal marker + optional webhook)
# ═══════════════════════════════════════════════════════════════════════
info "disk-watch: threshold=${HYGIENE_DISK_ALERT_PCT}% webhook=$([ -n "$HYGIENE_DISK_WEBHOOK_URL" ] && echo on || echo off)"
if [ "$HYGIENE_DISK_ALERT_PCT" = "0" ]; then
	warn "disk-watch alarm disabled by HYGIENE_DISK_ALERT_PCT=0 — skipping"
	if is_systemd && [ -f /etc/systemd/system/disk-watch.timer ]; then
		systemctl_apply disable --now disk-watch.timer 2>/dev/null || true
		info "disk-watch timer disabled (unit files left in place)"
	fi
else
	# The webhook path needs curl; bring it in only when actually used.
	if [ -n "$HYGIENE_DISK_WEBHOOK_URL" ]; then
		apt_install curl
	fi
	ENV_FILE=/etc/host-hygiene.env
	WATCH=/usr/local/bin/host-hygiene-disk-watch.sh
	SERVICE=/etc/systemd/system/disk-watch.service
	TIMER=/etc/systemd/system/disk-watch.timer
	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would install env file, disk-watch watchdog + weekly timer (threshold ${HYGIENE_DISK_ALERT_PCT}%)"
	else
		mkdir -p /usr/local/bin /etc/systemd/system
		umask 077
		cat > "$ENV_FILE.tmp" <<EOF
# Host hygiene (L1) runtime config — written by scripts/host-hygiene.sh.
# Consumed by the disk-watch watchdog. Do not edit by hand; re-run the engine.
HYGIENE_DISK_ALERT_PCT=$HYGIENE_DISK_ALERT_PCT
HYGIENE_DISK_WEBHOOK_URL=$HYGIENE_DISK_WEBHOOK_URL
EOF
		mv -f "$ENV_FILE.tmp" "$ENV_FILE"
		chmod 0600 "$ENV_FILE"
		cat > "$WATCH.tmp" <<'EOF'
#!/bin/bash
# /usr/local/bin/host-hygiene-disk-watch.sh — generic root-disk capacity alarm.
# Emits a loud journald marker (user.warning) when root usage crosses the
# configured threshold, and optionally POSTs a JSON payload to a webhook.
# Installed by scripts/host-hygiene.sh; schedule: weekly systemd timer.
set -euo pipefail

# shellcheck disable=SC1091
. /etc/host-hygiene.env

USED=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
THRESHOLD=${HYGIENE_DISK_ALERT_PCT:-85}

if [ "${USED:-0}" -lt "$THRESHOLD" ]; then
	echo "root filesystem at ${USED}% (threshold ${THRESHOLD}%) — ok"
	exit 0
fi

MSG="[host-hygiene] DISK ALARM: root filesystem at ${USED}% (threshold ${THRESHOLD}%)"
logger -t host-hygiene -p user.warning "$MSG"
echo "$MSG"

if [ -n "${HYGIENE_DISK_WEBHOOK_URL:-}" ]; then
	PAYLOAD="{\"event\":\"disk-alarm\",\"host\":\"$(hostname)\",\"root_used_pct\":${USED},\"threshold_pct\":${THRESHOLD}}"
	HTTP_CODE=0
	if command -v curl >/dev/null 2>&1; then
		curl -fsS -m 15 -o /dev/null \
			-H 'Content-Type: application/json' \
			-d "$PAYLOAD" "$HYGIENE_DISK_WEBHOOK_URL" || HTTP_CODE=$?
	else
		wget -q -O /dev/null --timeout=15 \
			--header="Content-Type: application/json" \
			--post-data="$PAYLOAD" "$HYGIENE_DISK_WEBHOOK_URL" || HTTP_CODE=$?
	fi
	if [ "$HTTP_CODE" != 0 ]; then
		logger -t host-hygiene -p user.warning "disk-watch webhook POST failed (exit $HTTP_CODE)"
	fi
fi
EOF
		chmod 0755 "$WATCH.tmp"
		mv -f "$WATCH.tmp" "$WATCH"
		cat > "$SERVICE.tmp" <<'EOF'
[Unit]
Description=Host-hygiene disk-watch alarm (weekly)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/host-hygiene-disk-watch.sh
EOF
		mv -f "$SERVICE.tmp" "$SERVICE"
		cat > "$TIMER.tmp" <<'EOF'
[Unit]
Description=Weekly host-hygiene disk-watch alarm

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
		mv -f "$TIMER.tmp" "$TIMER"
		systemctl_apply daemon-reload
		systemctl_apply enable --now disk-watch.timer
		info "disk-watch timer installed and enabled (threshold ${HYGIENE_DISK_ALERT_PCT}%, webhook $([ -n "$HYGIENE_DISK_WEBHOOK_URL" ] && echo on || echo off))"
	fi
fi

# ═══════════════════════════════════════════════════════════════════════
# 5. sshd connection bounds (var-gated; 0/empty = do not manage sshd)
# ═══════════════════════════════════════════════════════════════════════
# Ships MaxStartups + MaxSessions + keepalives via /etc/ssh/sshd_config.d/
# 09-sshd-limits.conf. The 09- prefix sorts BEFORE the retired L2 repo's
# `10-l2.conf` (MaxStartups 3:50:10): sshd's Include sits at the TOP of
# sshd_config and sshd keeps the FIRST value it reads, so the earlier-
# sorting drop-in always wins. Evidence (DarojaAI/terraform-hcloud-linux-vm
# #9): 54 `drop connection ... Maxstartups` events in 6 h on the test VM —
# from the 3rd concurrent unauthenticated connection the 3:50:10 policy
# drops 50% at random, so internet scanners starve GitHub Actions runners
# (every deploy's SSH layer flaked with `kex_exchange_identification: read:
# Connection reset by peer`).
#
# Legacy migration (explicit, evidence-preserving; installs only — nothing
# is deleted): a `10-l2.conf` that still carries `MaxStartups 3:50:10` is
# renamed in place to `10-l2.conf.disabled-<UTC ts>`. Any other content is
# left untouched.

# Renders the drop-in from the configured knobs. Pure function (stdout) so
# tests/sshd-limits.bats can render it into a temp dir hermetically without
# running the engine against the real /etc/ssh.
sshd_limits_dropin() {
	cat <<-EOF
	# sshd connection bounds - L1 host hygiene (scripts/host-hygiene.sh section 5).
	# Hardens the SSH surface against connection-exhaustion flakes (issue #9).
	# This file sorts BEFORE the retired L2 repo's 10-l2.conf (MaxStartups
	# 3:50:10): sshd Include sits at the top of sshd_config and sshd keeps the
	# FIRST value it reads, so 09- wins. Evidence: 54 'drop connection ...
	# Maxstartups' events in 6 h on the test VM; CI runners failed with
	# 'kex_exchange_identification: read: Connection reset by peer'.
	MaxStartups $HYGIENE_SSHD_MAX_STARTUPS
	MaxSessions $HYGIENE_SSHD_MAX_SESSIONS
	ClientAliveInterval $HYGIENE_SSHD_KEEPALIVE_INTERVAL
	ClientAliveCountMax $HYGIENE_SSHD_KEEPALIVE_COUNT
	EOF
}

SSHD_CONFIG_D=/etc/ssh/sshd_config.d
SSH_DROP_IN=$SSHD_CONFIG_D/09-sshd-limits.conf
LEGACY_DROP_IN=$SSHD_CONFIG_D/10-l2.conf

# Gate: `0` or an explicitly empty value opts out of sshd management entirely
# (the other HYGIENE_SSHD_* knobs are then ignored); unset falls back to the
# module default 40:30:100 so the engine stays valid standalone.
SSHD_MANAGE=1
if [ -n "${HYGIENE_SSHD_MAX_STARTUPS+x}" ]; then
	if [ -z "$HYGIENE_SSHD_MAX_STARTUPS" ] || [ "$HYGIENE_SSHD_MAX_STARTUPS" = "0" ]; then
		SSHD_MANAGE=0
	fi
fi
if [ "$SSHD_MANAGE" = 0 ]; then
	warn "sshd bounds: skipped — HYGIENE_SSHD_MAX_STARTUPS is 0/empty (sshd not managed)"
else
	: "${HYGIENE_SSHD_MAX_STARTUPS:=40:30:100}"
	info "sshd bounds: max_startups=$HYGIENE_SSHD_MAX_STARTUPS max_sessions=$HYGIENE_SSHD_MAX_SESSIONS keepalive=${HYGIENE_SSHD_KEEPALIVE_INTERVAL}s x${HYGIENE_SSHD_KEEPALIVE_COUNT} -> $SSH_DROP_IN"

	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would write $SSH_DROP_IN (mode 0644)"
		if [ -f "$LEGACY_DROP_IN" ] && grep -qi '^[[:space:]]*maxstartups[[:space:]]*3:50:10' "$LEGACY_DROP_IN"; then
			warn "DRY RUN: would rename $LEGACY_DROP_IN to $LEGACY_DROP_IN.disabled-$(date -u +%Y%m%dT%H%M%SZ) (still sets MaxStartups 3:50:10 from the retired L2 repo — would shadow this 09- drop-in)"
		fi
		info "DRY RUN: would run: sshd -t; systemctl reload ssh (fallback: sshd); then assert 'sshd -T | grep -i ^maxstartups' == $HYGIENE_SSHD_MAX_STARTUPS"
	else
		mkdir -p "$SSHD_CONFIG_D"
		sshd_limits_dropin > "$SSH_DROP_IN.tmp"
		chmod 0644 "$SSH_DROP_IN.tmp"
		mv -f "$SSH_DROP_IN.tmp" "$SSH_DROP_IN"
		info "sshd bounds written: MaxStartups=$HYGIENE_SSHD_MAX_STARTUPS MaxSessions=$HYGIENE_SSHD_MAX_SESSIONS keepalive=${HYGIENE_SSHD_KEEPALIVE_INTERVAL}s x${HYGIENE_SSHD_KEEPALIVE_COUNT} ($SSH_DROP_IN, mode 0644)"

		# Legacy migration: rename (never delete) any 10-l2.conf that still
		# sets the retired L2 repo's MaxStartups 3:50:10, so it can no longer
		# shadow this drop-in. Any other content is left untouched.
		if [ -f "$LEGACY_DROP_IN" ] && grep -qi '^[[:space:]]*maxstartups[[:space:]]*3:50:10' "$LEGACY_DROP_IN"; then
			LEGACY_RENAMED="$LEGACY_DROP_IN.disabled-$(date -u +%Y%m%dT%H%M%SZ)"
			mv -f "$LEGACY_DROP_IN" "$LEGACY_RENAMED"
			warn "renamed $LEGACY_DROP_IN -> $LEGACY_RENAMED (sets MaxStartups 3:50:10 from the retired L2 repo; the L1 09- drop-in now owns sshd bounds)"
		fi

		# Fail loud, restore nothing silently: validate the config, reload
		# sshd, then assert the effective value sshd actually reads.
		sshd -t
		if ! systemctl reload ssh 2>/dev/null; then
			systemctl reload sshd
		fi
		EFFECTIVE=$(sshd -T | grep -i '^maxstartups' | awk '{print $2}')
		if [ "$EFFECTIVE" != "$HYGIENE_SSHD_MAX_STARTUPS" ]; then
			error "sshd bounds assertion FAILED: effective MaxStartups is '$EFFECTIVE', expected '$HYGIENE_SSHD_MAX_STARTUPS' ($SSH_DROP_IN)"
			exit 1
		fi
		info "sshd bounds verified: sshd -T reports maxstartups $EFFECTIVE (as configured)"
	fi
fi

# ── Summary ──
info "host-hygiene run complete (dry-run=$([ -n "$HYGIENE_DRY_RUN" ] && echo yes || echo no))"