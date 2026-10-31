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
#     (dry-run by default, --apply installs; --check now included).
#
# Modes:
#   bare run / --apply  install (root) — writes every managed artifact.
#   HYGIENE_DRY_RUN=1   print what would change, touch nothing.
#   --check             READ-ONLY drift report — renders every managed
#                       artifact into a temp dir and compares it with the
#                       live system. No root required. Exit codes:
#                         0 = clean; 1 = drift (one line per artifact +
#                       summary count); 2 = cannot evaluate (unreadable live
#                       file or a render failed). Never mutates anything,
#                       never reloads, never calls systemctl/sshd/apt.
#
# Configuration comes from HYGIENE_* environment variables with the module's
# defaults below, so the engine is valid standalone. Idempotent: safe to
# re-run any time. Installs only — never deletes anything by hand.
set -eo pipefail

SELF_COPY=/opt/host-hygiene.sh

# ── Minimal helpers (self-contained — L1 module owns this, no lib.sh) ──
__log() { echo "[$(date -Iseconds)] [$1] $2"; }
info()  { __log "INFO"  "$1"; }
warn()  { __log "WARN"  "$1"; }
error() { __log "ERROR" "$1"; }

usage() {
	cat <<'EOF'
Usage: bash scripts/host-hygiene.sh [--check]

  bare run / --apply : install (apply) — as root, writes every managed artifact.
  --check            : READ-ONLY drift report. Renders every managed artifact
                       into a temp dir and compares it byte-for-byte with the
                       live file. No root required. Exit codes:
                         0 = clean; 1 = drift (one line per artifact plus a
                       summary count); 2 = cannot evaluate (unreadable live
                       file, or a render failed). Never mutates, never reloads,
                       never calls systemctl/sshd/apt.
  HYGIENE_DRY_RUN=1   : print what would change without touching anything.

  HYGIENE_ROOT (optional) overrides the live filesystem root for --check,
  so hermetic tests can compare against a fixture tree.
EOF
}

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
# In --check mode it is never run (the check is read-only by contract).
systemctl_apply() {
	if [ "$MODE" = check ]; then
		warn "check: would run: systemctl $* (skipped — check is read-only)"
		return 0
	fi
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

# ── Mode dispatch ──
MODE=apply
for arg in "$@"; do
	# Only --check is a distinct mode; a bare run keeps the historical
	# apply-by-default contract (bootstrap-hygiene.sh owns dry-run/--apply).
	case "$arg" in
		--check) MODE=check ;;
		-h|--help) usage; exit 0 ;;
		*) error "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
	esac
done

if [ "$MODE" = check ]; then
	CHECK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/host-hygiene-check.XXXXXX") || {
		error "cannot create temp dir for --check"
		exit 2
	}
	trap 'rm -rf "$CHECK_TMP"' EXIT
	info "check mode: rendering managed artifacts into $CHECK_TMP; live comparison below (read-only)"
fi

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
# Never in --check mode: a check must not write anything anywhere.
if [ -z "$HYGIENE_DRY_RUN" ] && [ "$MODE" != check ] && [ "$(readlink -f "$0")" != "$SELF_COPY" ]; then
	mkdir -p "$(dirname "$SELF_COPY")"
	cp "$0" "$SELF_COPY.tmp"
	chmod 0755 "$SELF_COPY.tmp"
	mv "$SELF_COPY.tmp" "$SELF_COPY"
	info "saved canonical engine to $SELF_COPY (re-run: sudo bash $SELF_COPY)"
fi

# ═══════════════════════════════════════════════════════════════════════
# Pure render functions — the single source of truth for BOTH the apply
# writes and the --check comparison. Each renders its artifact's exact
# content to stdout (so tests/sshd-limits.bats and tests/hygiene-check.bats
# can extract them hermetically), and must stay byte-identical to what the
# apply path installs: --check compares the rendered bytes with the live
# file, so any drift between render and apply would show up as false drift
# (or, worse, hide real drift that differs in the same way).
# ═══════════════════════════════════════════════════════════════════════

# 1. journald cap
render_journald_dropin() {
	printf '[Journal]\nSystemMaxUse=%s\n' "$HYGIENE_JOURNALD_MAX_USE"
}

# 2. docker-prune units (only rendered/installed when docker exists & gate on)
render_docker_prune_service() {
	cat <<EOF
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
}

render_docker_prune_timer() {
	cat <<'EOF'
[Unit]
Description=Weekly host-hygiene docker prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# 3. unattended security-only auto-upgrades (no auto-reboot)
render_apt_auto_upgrades() {
	cat <<'EOF'
// Host hygiene (L1, generic): daily apt-lists refresh + unattended-upgrades.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

render_apt_unattended() {
	cat <<'EOF'
// Host hygiene (L1, generic): SECURITY-ONLY automatic upgrades, no reboot.
// ${distro_id}/${distro_codename} are expanded by apt, not by this script.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF
}

# 4. generic disk-watch alarm (weekly; loud journal marker + optional webhook)
render_host_hygiene_env() {
	cat <<EOF
# Host hygiene (L1) runtime config — written by scripts/host-hygiene.sh.
# Consumed by the disk-watch watchdog. Do not edit by hand; re-run the engine.
HYGIENE_DISK_ALERT_PCT=$HYGIENE_DISK_ALERT_PCT
HYGIENE_DISK_WEBHOOK_URL=$HYGIENE_DISK_WEBHOOK_URL
EOF
}

render_disk_watch_script() {
	cat <<'EOF'
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
}

render_disk_watch_service() {
	cat <<'EOF'
[Unit]
Description=Host-hygiene disk-watch alarm (weekly)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/host-hygiene-disk-watch.sh
EOF
}

render_disk_watch_timer() {
	cat <<'EOF'
[Unit]
Description=Weekly host-hygiene disk-watch alarm

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# ═══════════════════════════════════════════════════════════════════════
# Artifact registry + writer — the single source of truth for --check.
# Every managed artifact registers (path + render fn + mode) at its write
# site, so the check enumerates exactly what the apply path manages: no
# hard-coded list that could drift. When sections are added later, they
# register here and --check picks them up automatically.
# ═══════════════════════════════════════════════════════════════════════
if [ "$MODE" = check ]; then
	HYGIENE_ARTIFACTS=()
	HYGIENE_RENDER_FAILS=""
fi

hygiene_register() { # path, render_fn, mode
	HYGIENE_ARTIFACTS+=("$1|$2|$3")
}

# Render+install an artifact, or in --check mode render it into the temp dir
# and register it for comparison. mode is the chmod applied on install
# ('-' = keep umask default, matching the legacy inline writes).
hygiene_install() {
	local path="$1" fn="$2" mode="$3"
	hygiene_register "$path" "$fn" "$mode"
	if [ "$MODE" = check ]; then
		local dest="$CHECK_TMP${path}"
		mkdir -p "$(dirname "$dest")"
		if ! "$fn" > "$dest.tmp" 2>/dev/null; then
			HYGIENE_RENDER_FAILS="${HYGIENE_RENDER_FAILS} $path"
			return 0
		fi
		mv -f "$dest.tmp" "$dest"
		return 0
	fi
	mkdir -p "$(dirname "$path")"
	"$fn" > "$path.tmp"
	[ "$mode" = "-" ] || chmod "$mode" "$path.tmp"
	mv -f "$path.tmp" "$path"
}

# ═══════════════════════════════════════════════════════════════════════
# 1. journald cap
# ═══════════════════════════════════════════════════════════════════════
JOURNALD_DROP_IN=/etc/systemd/journald.conf.d/90-host-hygiene.conf
info "journald: cap SystemMaxUse=$HYGIENE_JOURNALD_MAX_USE"
if [ -n "$HYGIENE_DRY_RUN" ]; then
	info "DRY RUN: would write $JOURNALD_DROP_IN and restart systemd-journald"
else
	hygiene_install "$JOURNALD_DROP_IN" render_journald_dropin 0644
	if [ "$MODE" = apply ]; then
		info "journald cap written: SystemMaxUse=$HYGIENE_JOURNALD_MAX_USE ($JOURNALD_DROP_IN)"
	fi
fi
if [ "$MODE" = apply ]; then
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
	if [ "$MODE" = apply ] && is_systemd && [ -f /etc/systemd/system/docker-prune.timer ]; then
		systemctl_apply disable --now docker-prune.timer 2>/dev/null || true
		info "docker-prune timer disabled (unit files left in place; re-enable: HYGIENE_DOCKER_PRUNE=true re-run)"
	fi
else
	SERVICE=/etc/systemd/system/docker-prune.service
	TIMER=/etc/systemd/system/docker-prune.timer
	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would install $SERVICE + $TIMER (prune all --filter until=$HYGIENE_DOCKER_PRUNE_UNTIL) and enable docker-prune.timer"
	else
		hygiene_install "$SERVICE" render_docker_prune_service 0644
		hygiene_install "$TIMER" render_docker_prune_timer 0644
		if [ "$MODE" = apply ]; then
			systemctl_apply daemon-reload
			systemctl_apply enable --now docker-prune.timer
			info "docker-prune timer installed and enabled (until=$HYGIENE_DOCKER_PRUNE_UNTIL)"
		fi
	fi
fi

# ═══════════════════════════════════════════════════════════════════════
# 3. unattended security-only auto-upgrades (no auto-reboot)
# ═══════════════════════════════════════════════════════════════════════
info "unattended-upgrades: gate=$HYGIENE_UNATTENDED_UPGRADES"
if [ "$HYGIENE_UNATTENDED_UPGRADES" != "true" ]; then
	warn "unattended-upgrades disabled — skipping (previously written apt fragments stay active)"
else
	AUTO_CONF=/etc/apt/apt.conf.d/52host-hygiene-auto-upgrades
	UNATT_CONF=/etc/apt/apt.conf.d/52host-hygiene-unattended
	if [ "$MODE" != check ]; then
		# Package presence is asserted in apply AND dry-run (prints state, or a
		# DRY-RUN would-install line); check mode is read-only and skips it —
		# only the two managed apt fragments are rendered and compared there.
		apt_install unattended-upgrades
		if [ -n "$HYGIENE_DRY_RUN" ]; then
			info "DRY RUN: would write $AUTO_CONF and $UNATT_CONF (security-only origins, no auto-reboot)"
		else
			mkdir -p /etc/apt/apt.conf.d
			hygiene_install "$AUTO_CONF" render_apt_auto_upgrades 0644
			hygiene_install "$UNATT_CONF" render_apt_unattended 0644
			info "unattended-upgrades configured: security-only origins, no auto-reboot ($AUTO_CONF, $UNATT_CONF)"
		fi
	else
		hygiene_install "$AUTO_CONF" render_apt_auto_upgrades 0644
		hygiene_install "$UNATT_CONF" render_apt_unattended 0644
	fi
fi

# ═══════════════════════════════════════════════════════════════════════
# 4. generic disk-watch alarm (weekly; loud journal marker + optional webhook)
# ═══════════════════════════════════════════════════════════════════════
info "disk-watch: threshold=${HYGIENE_DISK_ALERT_PCT}% webhook=$([ -n "$HYGIENE_DISK_WEBHOOK_URL" ] && echo on || echo off)"
if [ "$HYGIENE_DISK_ALERT_PCT" = "0" ]; then
	warn "disk-watch alarm disabled by HYGIENE_DISK_ALERT_PCT=0 — skipping"
	if [ "$MODE" = apply ] && is_systemd && [ -f /etc/systemd/system/disk-watch.timer ]; then
		systemctl_apply disable --now disk-watch.timer 2>/dev/null || true
		info "disk-watch timer disabled (unit files left in place)"
	fi
else
	ENV_FILE=/etc/host-hygiene.env
	WATCH=/usr/local/bin/host-hygiene-disk-watch.sh
	SERVICE=/etc/systemd/system/disk-watch.service
	TIMER=/etc/systemd/system/disk-watch.timer
	if [ "$MODE" != check ]; then
		# The webhook path needs curl; bring it in only when actually used
		# (asserted in apply AND dry-run, exactly like unattended-upgrades).
		if [ -n "$HYGIENE_DISK_WEBHOOK_URL" ]; then
			apt_install curl
		fi
	fi
	if [ "$MODE" = check ]; then
		# Render all four artifacts for comparison; nothing is installed.
		hygiene_install "$ENV_FILE" render_host_hygiene_env 0600
		hygiene_install "$WATCH" render_disk_watch_script 0755
		hygiene_install "$SERVICE" render_disk_watch_service 0644
		hygiene_install "$TIMER" render_disk_watch_timer 0644
	elif [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would install env file, disk-watch watchdog + weekly timer (threshold ${HYGIENE_DISK_ALERT_PCT}%)"
	else
		mkdir -p /usr/local/bin /etc/systemd/system
		umask 077
		hygiene_install "$ENV_FILE" render_host_hygiene_env 0600
		hygiene_install "$WATCH" render_disk_watch_script 0755
		hygiene_install "$SERVICE" render_disk_watch_service -
		hygiene_install "$TIMER" render_disk_watch_timer -
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
		hygiene_install "$SSH_DROP_IN" sshd_limits_dropin 0644
		if [ "$MODE" = apply ]; then
			# Explicit idempotent mode re-assert on the live file: the generic
			# installer already chmods the staged copy, this also repairs a
			# drifted/foreign-mode drop-in that may pre-date this engine.
			chmod 0644 "$SSH_DROP_IN"
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
fi

# ═══════════════════════════════════════════════════════════════════════
# Check report (--check mode only)
# ═══════════════════════════════════════════════════════════════════════
# Prints one line per compared artifact plus a summary count, then exits:
#   0 = no drift; 1 = drift; 2 = cannot evaluate.
first_diff_line() { # rendered, live — prints first differing line number
	local i n1 n2
	n1=$(wc -l < "$1")
	n2=$(wc -l < "$2")
	if [ "$n1" -lt "$n2" ]; then i="$n1"; else i="$n2"; fi
	local n=1
	while [ "$n" -le "$i" ]; do
		if [ "$(sed -n "${n}p" "$1")" != "$(sed -n "${n}p" "$2")" ]; then
			echo "$n"
			return 0
		fi
		n=$((n + 1))
	done
	# All common lines equal — the difference is in the line counts.
	if [ "$n1" -ne "$n2" ]; then
		if [ "$n1" -gt "$n2" ]; then echo "$((n2 + 1))"; else echo "$((n1 + 1))"; fi
	fi
}

hygiene_check_report() {
	local entry path fn mode rend live ok=0 drift=0 cannot=0 line rline lline
	for entry in "${HYGIENE_ARTIFACTS[@]}"; do
		path="${entry%%|*}"
		rest="${entry#*|}"
		fn="${rest%%|*}"
		mode="${rest#*|}"
		rend="$CHECK_TMP$path"
		if [ -n "${HYGIENE_ROOT:-}" ]; then live="$HYGIENE_ROOT/${path#/}"; else live="$path"; fi
		if [[ " $HYGIENE_RENDER_FAILS " == *" $path "* ]]; then
			printf 'CANNOT-EVALUATE %s  (render failed)\n' "$path"
			cannot=$((cannot + 1))
			continue
		fi
		if [ ! -e "$live" ]; then
			printf 'DRIFT    %s  (missing on live host)\n' "$path"
			drift=$((drift + 1))
			continue
		fi
		if [ ! -r "$live" ]; then
			printf 'CANNOT-EVALUATE %s  (live file not readable)\n' "$path"
			cannot=$((cannot + 1))
			continue
		fi
		if cmp -s "$rend" "$live"; then
			printf 'ok       %s\n' "$path"
			ok=$((ok + 1))
			continue
		fi
		line="$(first_diff_line "$rend" "$live")"
		rline="$(sed -n "${line}p" "$rend")"
		lline="$(sed -n "${line}p" "$live")"
		printf 'DRIFT    %s  (differs at line %s: live "%s" vs engine "%s")\n' "$path" "$line" "$lline" "$rline"
		drift=$((drift + 1))
	done
	printf 'check: %d artifacts compared — ok=%d, drift=%d, cannot-evaluate=%d\n' "${#HYGIENE_ARTIFACTS[@]}" "$ok" "$drift" "$cannot"
	[ "$cannot" -gt 0 ] && return 2
	[ "$drift" -gt 0 ] && return 1
	return 0
}

# ── Summary ──
if [ "$MODE" = check ]; then
	if hygiene_check_report; then
		RC=0
	else
		RC=$?
	fi
	info "host-hygiene --check complete: exit $RC"
	exit "$RC"
fi
info "host-hygiene run complete (dry-run=$([ -n "$HYGIENE_DRY_RUN" ] && echo yes || echo no))"
