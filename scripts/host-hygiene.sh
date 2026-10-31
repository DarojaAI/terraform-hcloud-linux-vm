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
#   6. fail2ban sshd ignoreip  — /etc/fail2ban/jail.d/10-lds-ignoreip.conf
#      (GitHub Actions runner ranges + weekly refresh unit)
#   6. sysctl forwarding       — /etc/sysctl.d/90-host-hygiene-forwarding.conf
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
#                       never reloads, never calls systemctl/sshd/apt/sysctl.
#
# Configuration comes from HYGIENE_* environment variables with the module's
# defaults below, so the engine is valid standalone. Idempotent: safe to
# re-run any time. Installs only — never deletes anything by hand.
set -eo pipefail

# HYGIENE_ROOT also redirects the canonical self-copy, so a hermetic apply
# test under a fixture root never writes the real /opt (prod: unset → /opt).
SELF_COPY="${HYGIENE_ROOT:-}/opt/host-hygiene.sh"

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
                       never calls systemctl/sshd/apt/sysctl.
  HYGIENE_DRY_RUN=1   : print what would change without touching anything.

  HYGIENE_ROOT (optional, test seam) overrides the live filesystem root for
  BOTH the --check comparison and the apply writes (incl. the canonical
  self-copy), so hermetic tests can run the full apply path against a
  fixture tree. Production: unset = real /.
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
# HYGIENE_SSHD_PERSOURCE_PENALTIES is deliberately NOT defaulted here
# either: unset falls back to the chosen lever `noauth:0` inside section 5
# (issue #11 — disables the pre-auth-connection priming term of OpenSSH
# 10.2's PerSourcePenalties, keeps every other keyword at the distro
# default); an explicitly EMPTY value leaves the distro policy untouched
# (no line rendered) and is logged.
# HYGIENE_DISK_WEBHOOK_URL is optional; empty/absent = webhook off.
: "${HYGIENE_SYSCTL_FORWARDING:=true}"

# Test seam: every live-filesystem write below goes through LIVE_ROOT (the
# same HYGIENE_ROOT --check compares against), so a hermetic apply run under
# a fixture tree never touches the real filesystem. Production: unset "".
LIVE_ROOT="${HYGIENE_ROOT:-}"

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
		if ! "$fn" > "$dest.tmp" 2>"$dest.err"; then
			# Carry the render's own reason (its first stderr line) into the
			# report — e.g. the fail2ban drop-in reports "cache absent — no
			# resolved CIDR list" instead of a generic "render failed".
			local reason
			reason=$(sed -n '1p' "$dest.err" 2>/dev/null)
			[ -n "$reason" ] || reason="render failed"
			HYGIENE_RENDER_FAILS="${HYGIENE_RENDER_FAILS}${path}|${reason}"$'\n'
			rm -f "$dest.tmp" "$dest.err"
			return 0
		fi
		rm -f "$dest.err"
		mv -f "$dest.tmp" "$dest"
		return 0
	fi
	local dest="$LIVE_ROOT$path"
	mkdir -p "$(dirname "$dest")"
	"$fn" > "$dest.tmp"
	[ "$mode" = "-" ] || chmod "$mode" "$dest.tmp"
	mv -f "$dest.tmp" "$dest"
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
	if [ "$MODE" = apply ] && is_systemd && [ -f "$LIVE_ROOT/etc/systemd/system/docker-prune.timer" ]; then
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
			mkdir -p "$LIVE_ROOT/etc/apt/apt.conf.d"
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
	if [ "$MODE" = apply ] && is_systemd && [ -f "$LIVE_ROOT/etc/systemd/system/disk-watch.timer" ]; then
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
		mkdir -p "$LIVE_ROOT/usr/local/bin" "$LIVE_ROOT/etc/systemd/system"
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
# PerSourcePenalties is a SECOND, independent copy of that identical error
# (DarojaAI/terraform-hcloud-linux-vm #11). OpenSSH 10.2 enables it by
# default on this box (`sshd -T`):
#   persourcepenalties crash:90 authfail:5 noauth:1 grace-exceeded:10
#   refuseconnection:10 max:600 min:15 ...
# Measured mechanics (10.2p1 source: srclimit.c/sshd.c/servconf.c, matched
# to host logs): penalties only ACCRUE — each offence extends the source's
# expiry (existing->expiry += secs) up to max:600 and activation starts past
# min:15; there is no decay. The noauth:1 term fires in child_reap() for any
# pre-auth connection that closes without authenticating, so a CI deploy's
# ~30 SSH/scp connections from one runner IP plus retries accumulate 30s+
# (> min:15), get refused, and each retry re-extends the window toward the
# 600s cap. The refusal happens in the SAME drop_connection() path as
# MaxStartups ("Not allowed at this time\r\n", no banner) — byte-identical
# client error, invisible to the old MaxStartups-only observability. Host
# logs confirm real activations: 127.0.0.1 authfail 20s + drop bursts, and
# scanners penalized for exceeded LoginGraceTime (16-20s) — so the crash/
# authfail/grace-exceeded protections are doing useful work and stay on.
#
# Lever choice (see issue-shaped discussion above): disabling the whole
# feature (`no`) or exempting CI egress ranges (PerSourcePenaltyExemptList)
# would shed real scanner protection or bake dynamic runner IPs into a
# generic module; capping `max` only shortens the outage while retries keep
# re-extending to the cap. The surgical lever is RELAXING ONLY the priming
# term to `noauth:0` (a partial override — unspecified keywords keep their
# distro defaults): pre-auth connection bursts no longer accrue, while
# crash/authfail/grace-exceeded/refuseconnection/min/max stay exactly as
# measured above. sshd_config(5) itself warns noauth "should be used
# cautiously otherwise it may penalise legitimate scanning tools such as
# ssh-keyscan(1)".
#
# Legacy migration (explicit, evidence-preserving; installs only — nothing
# is deleted): a `10-l2.conf` that still carries `MaxStartups 3:50:10` is
# renamed in place to `10-l2.conf.disabled-<UTC ts>`. Any other content is
# left untouched.

# Renders the drop-in from the configured knobs. Pure function (stdout) so
# tests/sshd-limits.bats can render it into a temp dir hermetically without
# running the engine against the real /etc/ssh.
# PerSourcePenalties overrides (issue #11) render only when the knob is
# non-empty; `noauth:0` disables the pre-auth-connection priming term while
# every other keyword keeps its distro default (partial override).
sshd_limits_dropin() {
	cat <<-EOF
	# sshd connection bounds - L1 host hygiene (scripts/host-hygiene.sh section 5).
	# Hardens the SSH surface against connection-exhaustion flakes (issues #9 + #11).
	# This file sorts BEFORE the retired L2 repo's 10-l2.conf (MaxStartups
	# 3:50:10): sshd Include sits at the top of sshd_config and sshd keeps the
	# FIRST value it reads, so 09- wins. Evidence: 54 'drop connection ...
	# Maxstartups' events in 6 h on the test VM. PerSourcePenalties (enabled
	# by default in OpenSSH 10.2) has the SAME client-visible failure mode —
	# drop_connection() refuses with 'Not allowed at this time' before any
	# banner, hence the identical 'kex_exchange_identification: read:
	# Connection reset by peer' — see issue #11; the noauth term here is
	# 0 so benign pre-auth bursts from CI runner IPs cannot accrue a penalty.
	MaxStartups $HYGIENE_SSHD_MAX_STARTUPS
	MaxSessions $HYGIENE_SSHD_MAX_SESSIONS
	ClientAliveInterval $HYGIENE_SSHD_KEEPALIVE_INTERVAL
	ClientAliveCountMax $HYGIENE_SSHD_KEEPALIVE_COUNT
	EOF
	# Unset means the module default (noauth:0); an explicitly EMPTY value
	# means "leave the distro policy alone" and renders no line at all. The
	# default lives here, not only in the main flow, so the render (and the
	# --check comparison built from it) is a pure function of the env.
	psp_directive="${HYGIENE_SSHD_PERSOURCE_PENALTIES-noauth:0}"
	if [ -n "$psp_directive" ]; then
		printf 'PerSourcePenalties %s\n' "$psp_directive"
	fi
}

# ── PerSourcePenalties effective-value assertion helpers (pure; subject to
#    the same hermetic tests as sshd_limits_dropin) ──
# sshd -T prints the FULL effective persourcepenalties policy line with
# durations normalized to seconds (e.g. `noauth:90s` -> `noauth:90`), so the
# post-reload assert compares term-by-term: every `key:value` we configured
# must appear in the effective tuple as `key:<convtime(value)>`.
# psp_term_seconds mirrors sshd's convtime(3): digits with an optional
# s/m/h/d/w suffix (compound allowed — 1m30s == 90s).
psp_term_seconds() {
	local val=$1 total=0 digits mult rest
	val=${val,,}
	while [ -n "$val" ]; do
		digits=${val%%[a-z]*}
		rest=${val#"$digits"}
		if [ -z "$digits" ]; then
			echo -1
			return 1
		fi
		mult=1
		case ${rest:0:1} in
			"") rest="" ;;
			s) mult=1 ;;
			m) mult=60 ;;
			h) mult=3600 ;;
			d) mult=86400 ;;
			w) mult=604800 ;;
			*) echo -1; return 1 ;;
		esac
		total=$(( total + digits * mult ))
		val=${rest:1}
	done
	echo "$total"
}

# Usage: psp_tuple_matches CONFIG "effective tuple"; returns 0 when every
# configured term is honored in sshd's effective policy.
psp_tuple_matches() {
	local expected=$1 effective=$2 term key want got eff
	for term in $expected; do
		key=${term%%:*}
		key=${key,,}
		want=$(psp_term_seconds "${term#*:}") || return 1
		got=""
		for eff in $effective; do
			case $eff in
				"$key:"*) got=${eff#*:}; break ;;
			esac
		done
		if [ -z "$got" ] || [ "$got" != "$want" ]; then
			return 1
		fi
	done
	return 0
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
	# PerSourcePenalties knob (issue #11): unset -> the chosen lever noauth:0
	# (partial override; other keywords keep distro defaults); explicitly
	# empty -> leave the distro policy untouched and log it.
	if [ -z "${HYGIENE_SSHD_PERSOURCE_PENALTIES+x}" ]; then
		HYGIENE_SSHD_PERSOURCE_PENALTIES=noauth:0
	fi
	info "sshd bounds: max_startups=$HYGIENE_SSHD_MAX_STARTUPS max_sessions=$HYGIENE_SSHD_MAX_SESSIONS keepalive=${HYGIENE_SSHD_KEEPALIVE_INTERVAL}s x${HYGIENE_SSHD_KEEPALIVE_COUNT} -> $SSH_DROP_IN"
	if [ -n "$HYGIENE_SSHD_PERSOURCE_PENALTIES" ]; then
		info "sshd bounds: per_source_penalties=$HYGIENE_SSHD_PERSOURCE_PENALTIES (will assert it in 'sshd -T' after reload)"
	else
		info "sshd bounds: per_source_penalties left at the distro default (HYGIENE_SSHD_PERSOURCE_PENALTIES is empty — no line rendered)"
	fi

	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would write $SSH_DROP_IN (mode 0644)"
		if [ -n "$HYGIENE_SSHD_PERSOURCE_PENALTIES" ]; then
			info "DRY RUN: would render 'PerSourcePenalties $HYGIENE_SSHD_PERSOURCE_PENALTIES' and assert it in 'sshd -T | grep -i persourcepenalties'"
		else
			info "DRY RUN: PerSourcePenalties left at the distro default (knob empty — no line in $SSH_DROP_IN)"
		fi
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
			chmod 0644 "$LIVE_ROOT$SSH_DROP_IN"
			info "sshd bounds written: MaxStartups=$HYGIENE_SSHD_MAX_STARTUPS MaxSessions=$HYGIENE_SSHD_MAX_SESSIONS keepalive=${HYGIENE_SSHD_KEEPALIVE_INTERVAL}s x${HYGIENE_SSHD_KEEPALIVE_COUNT} ($SSH_DROP_IN, mode 0644)"

			# Legacy migration: rename (never delete) any 10-l2.conf that still
			# sets the retired L2 repo's MaxStartups 3:50:10, so it can no longer
			# shadow this drop-in. Any other content is left untouched.
			if [ -f "$LIVE_ROOT$LEGACY_DROP_IN" ] && grep -qi '^[[:space:]]*maxstartups[[:space:]]*3:50:10' "$LIVE_ROOT$LEGACY_DROP_IN"; then
				LEGACY_RENAMED="$LIVE_ROOT$LEGACY_DROP_IN.disabled-$(date -u +%Y%m%dT%H%M%SZ)"
				mv -f "$LIVE_ROOT$LEGACY_DROP_IN" "$LEGACY_RENAMED"
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
		# Effective-policy assertions run only in apply mode: --check must not
		# touch sshd at all (no reload, no -T probe against the live daemon).
		if [ "$MODE" = apply ]; then
			# PerSourcePenalties (issue #11). sshd -T prints the WHOLE effective
			# policy line with durations normalized to seconds (noauth:90s becomes
			# noauth:90), so a plain string compare is wrong twice: the printed
			# tuple always shows every keyword, and unit-form durations are
			# canonicalized. Assert instead that every configured keyword is
			# honored in the effective tuple.
			if [ -n "$HYGIENE_SSHD_PERSOURCE_PENALTIES" ]; then
				EFFECTIVE_PSP=$(sshd -T | sed -nE 's/^persourcepenalties[[:space:]]+//ip')
				if [ -z "$EFFECTIVE_PSP" ] || ! psp_tuple_matches "$HYGIENE_SSHD_PERSOURCE_PENALTIES" "$EFFECTIVE_PSP"; then
					error "sshd bounds assertion FAILED: sshd -T reports PerSourcePenalties as '${EFFECTIVE_PSP:-<no persourcepenalties line>}', configured '$HYGIENE_SSHD_PERSOURCE_PENALTIES' not honored ($SSH_DROP_IN)"
					exit 1
				fi
				info "sshd bounds verified: sshd -T reports PerSourcePenalties honoring '$HYGIENE_SSHD_PERSOURCE_PENALTIES'"
			else
				info "sshd bounds: PerSourcePenalties left at the distro default — effective (sshd -T): $(sshd -T | sed -nE 's/^persourcepenalties[[:space:]]+//ip')"
			fi
		fi
	fi
fi

# ═══════════════════════════════════════════════════════════════════════
# 6. fail2ban sshd ignoreip — GitHub Actions runner ranges (+ weekly refresh)
# ═══════════════════════════════════════════════════════════════════════
# The sshd jail (`maxretry 5`, `findtime 600`, `bantime 3600`) bans IPs that
# fail authentication. A GitHub Actions runner SSHing in mid-deploy lands as
# `Connection closed by authenticating user …` (the deploy's ssh-copy-id
# probe counts too — the jail can't tell a probe from an attack), so a runner
# IP was banned MID-deploy and the deploy burned its rc=255 retry budget and
# failed (issue #10). Prod showed 13 banned IPs, including two Azure
# addresses (4.182.219.135, 209.99.190.215) — the cloud hosted runners come
# from.
#
# Fix: a jail.d drop-in exempting the GitHub Actions runner egress ranges
# (https://api.github.com/meta -> "actions") from the sshd jail. The ranges
# are resolved at install time and re-resolved weekly by the
# fail2ban-ignoreip-refresh timer — GitHub updates the list weekly and it has
# grown to thousands of multi-cloud (Azure/AWS/…) CIDRs, so a one-time copy
# would go stale. Only "actions" is exempted, deliberately NOT "hooks": the
# hooks ranges are GitHub->server webhook deliveries that never SSH into the
# VM, so exempting them would widen the jail's blind spot for SSH scanners
# without fixing the runner problem.
#
# Network-failure safety: if the meta fetch fails at install/refresh time
# the ranges come from a static fallback DATA FILE (etc/fail2ban/
# github-actions-cidrs.txt in the repo, /opt/github-actions-cidrs.txt on the
# VM, path overridable via HYGIENE_FAIL2BAN_FALLBACK_FILE) — a dated snapshot
# captured verbatim from api.github.com/meta on 2026-10-31 (GitHub documents
# no static table and says allowlists must track ALL ranges in the actions
# array). If BOTH the live fetch and the fallback file are unavailable (or
# the file is malformed/empty), the section fails loudly and writes NO
# drop-in — never an empty or partial exemption.
#
# Deterministic range source: apply resolves the list (live meta first, then
# the static fallback), writes the RESOLVED list to a cache file
# (/var/lib/host-hygiene/fail2ban-cidrs.txt, HYGIENE_ROOT-relative under
# test) and renders the drop-in from that cache. --check renders from the
# cache too and never touches the network; a missing/unusable cache makes
# the drop-in CANNOT-EVALUATE instead of silently passing or fetching.
#
# Knobs: HYGIENE_FAIL2BAN_IGNOREIP (extra CIDRs appended to the ignoreip
# line; empty default) and HYGIENE_FAIL2BAN_REFRESH (true|false, default
# true — install the weekly refresh unit). Defaulted here, standalone-valid.

: "${HYGIENE_FAIL2BAN_IGNOREIP:=}"
: "${HYGIENE_FAIL2BAN_REFRESH:=true}"

# Network-failure safety: if the live meta fetch fails, the ranges come from
# the static fallback DATA FILE (one CIDR per line; data, never code):
#   etc/fail2ban/github-actions-cidrs.txt  (repo checkout layout)
#   /opt/github-actions-cidrs.txt          (VM: first-boot deploys it)
# Path overridable via HYGIENE_FAIL2BAN_FALLBACK_FILE. The file is a dated
# snapshot captured verbatim from api.github.com/meta ("actions") on
# 2026-10-31 — GitHub documents no static table and says allowlists must
# track ALL ranges in the actions array. If BOTH the live fetch and the
# fallback file are unavailable (or the file is malformed/empty), the
# resolver FAILS (non-zero) and the section refuses to write an empty or
# partial exemption — it is better to fail loudly than to silently strip
# the jail's protection.

# Validates a single CIDR token (IPv4 /1-/32 or IPv6 /1-/128). Shared by the
# live-fetch normaliser and the static-fallback file reader, so neither can
# ever admit a malformed exemption into the jail's allowlist.
fail2ban_cidr_ok() {
	local c="$1"
	[[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] && return 0
	[[ "$c" =~ ^[0-9a-fA-F:]+/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])$ ]] && return 0
	return 1
}

# Resolves the static fallback data file: $HYGIENE_FAIL2BAN_FALLBACK_FILE
# override first, then the repo checkout layout (etc/fail2ban/ next to the
# engine), then the VM deploy copy /opt/github-actions-cidrs.txt.
fail2ban_fallback_file() {
	local repo
	if [ -n "${HYGIENE_FAIL2BAN_FALLBACK_FILE:-}" ]; then
		printf '%s\n' "$HYGIENE_FAIL2BAN_FALLBACK_FILE"
		return 0
	fi
	repo="$(cd "$(dirname "$0")/.." && pwd)/etc/fail2ban/github-actions-cidrs.txt"
	if [ -f "$repo" ]; then
		printf '%s\n' "$repo"
		return 0
	fi
	printf '%s\n' "/opt/github-actions-cidrs.txt"
}


# Resolves the GitHub Actions runner egress ranges (api.github.com/meta ->
# top-level "actions"). Prints a single space-separated list of VALID CIDRs;
# source order: live fetch first, static fallback data file second. If both
# are unavailable — or the fallback file is malformed/empty — it prints
# NOTHING and returns non-zero so callers skip the drop-in write loudly
# (never an empty or partial exemption). Warnings go to stderr; stdout is the
# data channel, captured verbatim by the drop-in renderer and the generated
# weekly refresh helper.
fail2ban_github_actions() {
	local meta parsed token acc bad fallback line
	if command -v curl >/dev/null 2>&1; then
		meta=$(curl -fsSL --max-time 10 https://api.github.com/meta 2>/dev/null || true)
	fi
	if [ -z "$meta" ] && command -v wget >/dev/null 2>&1; then
		meta=$(wget -qO- --timeout=10 https://api.github.com/meta 2>/dev/null || true)
	fi
	if [ -n "$meta" ]; then
		# jq first — it needs VALID JSON, so operate on the raw meta (a
		# top-level ".actions"; the nested domains.actions block is never
		# selected by ".actions[]"). If jq is absent or fails, fall back to
		# the text parser.
		parsed=$(printf '%s' "$meta" | jq -r '.actions[]' 2>/dev/null | tr '\n' ' ' || true)
		if [ -z "${parsed// /}" ]; then
			# Text parser: flatten to one line, then drop the trailing
			# "domains" block (the only place an "actions" key recurs) so a
			# greedy match stays on the top-level array.
			meta=$(printf '%s' "$meta" | tr -d '\n' | sed 's/"domains".*//')
			parsed=$(printf '%s' "$meta" | sed -n 's/.*"actions"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr -d '\n" ' | tr ',' ' ' || true)
		fi
		acc=""
		bad=0
		for token in $parsed; do
			if fail2ban_cidr_ok "$token"; then
				acc="$acc $token"
			else
				bad=$((bad + 1))
			fi
		done
		if [ -n "${acc// /}" ]; then
			if [ "$bad" -gt 0 ]; then
				warn "fail2ban-ignoreip: dropped $bad unparseable CIDR(s) from api.github.com/meta (schema drift?)" >&2
			fi
			printf '%s' "${acc# }"
			return 0
		fi
		warn "fail2ban-ignoreip: api.github.com/meta yielded no valid CIDRs — trying the static fallback file" >&2
	fi

	# Static fallback data file (one CIDR per line; deploy path overridable).
	fallback="$(fail2ban_fallback_file)"
	if [ ! -r "$fallback" ]; then
		warn "fail2ban-ignoreip: no live GitHub ranges and static fallback unreadable ($fallback) — refusing to write an empty/partial ignoreip; fix network or point HYGIENE_FAIL2BAN_FALLBACK_FILE at a valid file" >&2
		return 2
	fi
	acc=""
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			\#*|"") continue ;;
		esac
		if ! fail2ban_cidr_ok "$line"; then
			warn "fail2ban-ignoreip: malformed CIDR \"$line\" in static fallback $fallback — file rejected (never a partial exemption)" >&2
			return 3
		fi
		acc="$acc $line"
	done < "$fallback"
	if [ -z "${acc// /}" ]; then
		warn "fail2ban-ignoreip: static fallback $fallback holds no CIDRs — refusing to write an empty/partial ignoreip" >&2
		return 4
	fi
	warn "fail2ban-ignoreip: using static fallback $fallback (live fetch unavailable)" >&2
	printf '%s' "${acc# }"
	return 0
}

# Renders /etc/fail2ban/jail.d/10-lds-ignoreip.conf — the SINGLE drop-in
# writer, shared verbatim by the engine's apply/check paths, the generated
# weekly refresh helper (its functions are emitted verbatim at generation
# time) and tests/fail2ban-ignoreip.bats. Pure function: stdout only, all
# inputs from env/args — the resolved CIDR list comes in as
# $FAIL2BAN_CIDRS (populated by apply from the resolver, by --check from
# the resolved-list cache), never from a fetch or a write.
fail2ban_ignoreip_dropin() {
	local ranges="${FAIL2BAN_CIDRS:-}"
	if [ -z "${ranges// /}" ]; then
		# Bare stderr line (no log prefix): hygiene_install captures the first
		# line of stderr as the --check CANNOT-EVALUATE reason, so this text
		# lands verbatim in the report.
		echo "no resolved CIDR list — the jail drop-in renders only from $FAIL2BAN_CACHE, which --apply fills at resolve time; check never fetches or writes (run --apply to resolve)" >&2
		return 2
	fi
	cat <<-EOF
	# fail2ban sshd ignoreip - L1 host hygiene (scripts/host-hygiene.sh section 6).
	# Exempts the GitHub Actions runner egress ranges from the sshd jail so a
	# runner IP cannot be banned mid-deploy (issue #10: the deploy's
	# ssh-copy-id probe + runner SSH land as 'Connection closed by
	# authenticating user' auth failures, which the jail counts; prod showed
	# 13 bans incl. Azure 4.182.219.135 / 209.99.190.215).
	# Ranges: resolved from https://api.github.com/meta -> "actions" at
	# apply time into the resolved-list cache ($FAIL2BAN_CACHE) and refreshed
	# weekly by fail2ban-ignoreip-refresh.timer (GitHub updates the list
	# weekly). If the fetch fails, the static fallback data file
	# (etc/fail2ban/github-actions-cidrs.txt, captured 2026-10-31; deployed
	# to /opt/github-actions-cidrs.txt) is resolved instead, so the jail
	# never loses its exemptions. "hooks" ranges are deliberately NOT
	# exempted (GitHub->VM webhook deliveries never SSH in). Extra ranges
	# come from HYGIENE_FAIL2BAN_IGNOREIP (empty by default).
	[sshd]
	ignoreip = 127.0.0.1/8 ::1 $ranges $HYGIENE_FAIL2BAN_IGNOREIP
	EOF
}

# Validates + reloads fail2ban ONLY when the drop-in actually changed.
# Shared by the engine's apply path and the generated weekly refresh helper
# (the functions are extracted into the helper verbatim at generation time,
# so the helper cannot drift from the engine). $1 = changed|unchanged.
fail2ban_ignoreip_reload() {
	local state="$1"
	if [ "$state" = "changed" ]; then
		if ! command -v fail2ban-client >/dev/null 2>&1; then
			warn "fail2ban-ignoreip: fail2ban-client not found — drop-in updated; validation+reload deferred until fail2ban is installed (re-run bootstrap after installing fail2ban)"
			return 0
		fi
		fail2ban-client -t
		if systemctl -q is-active fail2ban 2>/dev/null; then
			systemctl reload fail2ban
			info "fail2ban-ignoreip: validated (fail2ban-client -t) and reloaded after change"
		else
			warn "fail2ban-ignoreip: fail2ban service not active — validated config, reload deferred until fail2ban starts"
		fi
	else
		info "fail2ban-ignoreip: drop-in unchanged — no reload (idempotent)"
	fi
}

# Applies the drop-in (resolve -> persist cache -> render -> tmp -> cmp ->
# install-or-skip + conditional reload). The SAME function runs in the full
# engine apply path and in the generated weekly refresh helper — one
# implementation for both. The resolved-list cache is written ONLY here
# (never in --check, which reads it back read-only), so the cache is
# truthful by construction: it is exactly what the last apply resolved.
fail2ban_ignoreip_apply() {
	local ranges root
	root="${LIVE_ROOT:-}"
	ranges=$(fail2ban_github_actions) || return 2
	mkdir -p "$(dirname "$root$FAIL2BAN_CACHE")"
	printf '%s\n' "${ranges// /$'\n'}" > "$root$FAIL2BAN_CACHE.tmp"
	mv -f "$root$FAIL2BAN_CACHE.tmp" "$root$FAIL2BAN_CACHE"
	FAIL2BAN_CIDRS=$ranges
	mkdir -p "$root$FAIL2BAN_JAIL_D"
	if ! fail2ban_ignoreip_dropin > "$root$FAIL2BAN_DROP_IN.tmp"; then
		rm -f "$root$FAIL2BAN_DROP_IN.tmp"
		return 2
	fi
	chmod 0644 "$root$FAIL2BAN_DROP_IN.tmp"
	if cmp -s "$root$FAIL2BAN_DROP_IN.tmp" "$root$FAIL2BAN_DROP_IN"; then
		rm -f "$root$FAIL2BAN_DROP_IN.tmp"
		fail2ban_ignoreip_reload unchanged
	else
		mv -f "$root$FAIL2BAN_DROP_IN.tmp" "$root$FAIL2BAN_DROP_IN"
		info "fail2ban-ignoreip: wrote $FAIL2BAN_DROP_IN (mode 0644)"
		fail2ban_ignoreip_reload changed
	fi
}

FAIL2BAN_JAIL_D=/etc/fail2ban/jail.d
FAIL2BAN_DROP_IN=$FAIL2BAN_JAIL_D/10-lds-ignoreip.conf
# Resolved-list cache: the deterministic input for the drop-in render, read
# back by --check. One valid CIDR per line, written only by apply
# (fail2ban_ignoreip_apply); HYGIENE_ROOT-relative under test.
FAIL2BAN_CACHE=/var/lib/host-hygiene/fail2ban-cidrs.txt
FAIL2BAN_REFRESH_SCRIPT=/usr/local/bin/fail2ban-ignoreip-refresh.sh
FAIL2BAN_REFRESH_SERVICE=/etc/systemd/system/fail2ban-ignoreip-refresh.service
FAIL2BAN_REFRESH_TIMER=/etc/systemd/system/fail2ban-ignoreip-refresh.timer

# Renders the weekly refresh unit pair — pure function, printed to stdout:
#   fail2ban_refresh_unit service | fail2ban_refresh_unit timer
fail2ban_refresh_unit() {
	case "$1" in
		service)
			cat <<-EOF
			[Unit]
			Description=Refresh fail2ban sshd ignoreip from GitHub Actions ranges (L1 host hygiene)
			Documentation=https://docs.github.com/en/rest/meta/meta#get-github-meta-information
			After=network-online.target
			Wants=network-online.target

			[Service]
			Type=oneshot
			# Re-resolves api.github.com/meta -> "actions" and reloads fail2ban
			# ONLY when the rendered drop-in changed. Same single drop-in
			# writer as the engine's section 6 (extracted verbatim into
			# $FAIL2BAN_REFRESH_SCRIPT at generation time).
			ExecStart=$FAIL2BAN_REFRESH_SCRIPT
			EOF
			;;
		timer)
			cat <<-EOF
			[Unit]
			Description=Weekly refresh of fail2ban sshd ignoreip (GitHub Actions ranges)

			[Timer]
			OnCalendar=weekly
			Persistent=false

			[Install]
			WantedBy=timers.target
			EOF
			;;
	esac
}

# Arg-less renders for the unit pair — the shape hygiene_install expects
# (fn invoked with no arguments); fail2ban_refresh_unit stays the shared
# renderer for direct test extraction.
render_fail2ban_refresh_service() {
	fail2ban_refresh_unit service
}
render_fail2ban_refresh_timer() {
	fail2ban_refresh_unit timer
}

# Renders the generated weekly refresh helper (fail2ban-ignoreip-refresh.sh)
# — pure, stdout only: every embedded fail2ban_* function body is emitted
# from the LIVE shell via `declare -f` (no file reads, no fetch, no writes),
# so the helper installed by apply is byte-identical to the one --check
# renders, and it can never drift from the engine's own functions.
render_fail2ban_ignoreip_refresh_script() {
	cat <<'F2B_REFRESH_HDR'
#!/bin/bash
# fail2ban-ignoreip-refresh.sh — weekly re-resolve of the GitHub Actions
# runner ranges into the fail2ban sshd ignoreip drop-in.
# GENERATED by scripts/host-hygiene.sh section 6. Single implementation:
# the fail2ban_* functions below were emitted verbatim from the canonical
# engine at generation time, so this helper cannot drift from it. The static
# fallback data file is read from disk at runtime (never embedded here).
set -eo pipefail
__log() { echo "[$(date -Iseconds)] [$1] $2"; }
info()  { __log "INFO" "$1"; }
warn()  { __log "WARN" "$1"; }
FAIL2BAN_JAIL_D=/etc/fail2ban/jail.d
FAIL2BAN_DROP_IN=$FAIL2BAN_JAIL_D/10-lds-ignoreip.conf
FAIL2BAN_CACHE=/var/lib/host-hygiene/fail2ban-cidrs.txt
F2B_REFRESH_HDR
	declare -f fail2ban_cidr_ok
	declare -f fail2ban_fallback_file
	declare -f fail2ban_github_actions
	declare -f fail2ban_ignoreip_dropin
	declare -f fail2ban_ignoreip_reload
	declare -f fail2ban_ignoreip_apply
	printf '%s\n' "fail2ban_ignoreip_apply"
}

info "fail2ban-ignoreip: drop-in=$FAIL2BAN_DROP_IN cache=$FAIL2BAN_CACHE refresh=$HYGIENE_FAIL2BAN_REFRESH extra_ips=${HYGIENE_FAIL2BAN_IGNOREIP:-none}"
if [ "$MODE" = check ]; then
	# Read-only: render every fail2ban artifact for comparison and let the
	# report decide. The drop-in renders from the RESOLVED-LIST CACHE only —
	# --check never fetches (no curl/wget), never writes (no cache write, no
	# daemon-reload, no timer enable, no fail2ban-client) and never resolves:
	# the cache IS the deterministic range source. An absent/unusable cache
	# makes the drop-in CANNOT-EVALUATE (the expected content is unknowable
	# without the resolved list; a check must not fetch or fabricate it).
	cache_live="$FAIL2BAN_CACHE"
	[ -n "${HYGIENE_ROOT:-}" ] && cache_live="$HYGIENE_ROOT/${FAIL2BAN_CACHE#/}"
	FAIL2BAN_CIDRS=""
	if [ -r "$cache_live" ]; then
		cache_acc=""
		while IFS= read -r cache_line || [ -n "$cache_line" ]; do
			case "$cache_line" in
				\#*|"") continue ;;
			esac
			if fail2ban_cidr_ok "$cache_line"; then
				cache_acc="$cache_acc $cache_line"
			else
				warn "fail2ban-ignoreip: malformed CIDR \"$cache_line\" in resolved-list cache $cache_live — refusing to evaluate against a partial list" >&2
				cache_acc=""
				break
			fi
		done < "$cache_live"
		FAIL2BAN_CIDRS="${cache_acc# }"
	else
		warn "fail2ban-ignoreip: resolved-list cache missing ($cache_live) — cannot evaluate the drop-in without it (check is read-only: no fetch, no write); run --apply to resolve and cache the list" >&2
	fi
	hygiene_install "$FAIL2BAN_DROP_IN" fail2ban_ignoreip_dropin 0644
	# The refresh trio is checked under the SAME gate apply installs it:
	# refresh enabled AND fail2ban-client present.
	if [ "$HYGIENE_FAIL2BAN_REFRESH" = "true" ] && command -v fail2ban-client >/dev/null 2>&1; then
		hygiene_install "$FAIL2BAN_REFRESH_SCRIPT" render_fail2ban_ignoreip_refresh_script 0755
		hygiene_install "$FAIL2BAN_REFRESH_SERVICE" render_fail2ban_refresh_service 0644
		hygiene_install "$FAIL2BAN_REFRESH_TIMER"   render_fail2ban_refresh_timer 0644
	else
		if [ "$HYGIENE_FAIL2BAN_REFRESH" = "true" ]; then
			warn "fail2ban-ignoreip refresh: not checked — fail2ban-client not found (matches apply: the refresh unit is only installed when fail2ban is present)"
		else
			warn "fail2ban-ignoreip refresh: not checked — HYGIENE_FAIL2BAN_REFRESH=$HYGIENE_FAIL2BAN_REFRESH (matches apply's skip)"
		fi
	fi
elif [ -n "$HYGIENE_DRY_RUN" ]; then
	# Resolve (network permitted — dry-run prints the real rendered content);
	# the cache itself is written only by real apply.
	if ! ranges=$(fail2ban_github_actions); then
		error "fail2ban-ignoreip: cannot resolve GitHub ranges (live fetch failed and static fallback file unavailable/malformed) — skipping the drop-in write (never an empty/partial exemption); fix network or point HYGIENE_FAIL2BAN_FALLBACK_FILE at a valid file"
		exit 1
	fi
	FAIL2BAN_CIDRS=$ranges
	rendered=$(fail2ban_ignoreip_dropin)
	info "DRY RUN: would write $FAIL2BAN_CACHE (resolved ranges) and $FAIL2BAN_DROP_IN (mode 0644) — rendered content:"
	printf '%s\n' "$rendered" | sed 's/^/    | /'
	if [ "$HYGIENE_FAIL2BAN_REFRESH" != "true" ]; then
		info "DRY RUN: refresh unit skipped (HYGIENE_FAIL2BAN_REFRESH=$HYGIENE_FAIL2BAN_REFRESH)"
	elif command -v fail2ban-client >/dev/null 2>&1; then
		info "DRY RUN: would install $FAIL2BAN_REFRESH_SCRIPT + $FAIL2BAN_REFRESH_SERVICE + $FAIL2BAN_REFRESH_TIMER and enable fail2ban-ignoreip-refresh.timer (weekly, Persistent=false)"
	else
		info "DRY RUN: refresh unit deferred — fail2ban not installed on this host (drop-in still staged)"
	fi
	info "DRY RUN: would run: fail2ban-client -t (when installed); systemctl reload fail2ban only when $FAIL2BAN_DROP_IN changed"
else
	if ! fail2ban_ignoreip_apply; then
		error "fail2ban-ignoreip: unable to render the drop-in (live fetch and static fallback file both unavailable) — skipping the write (never an empty/partial exemption)"
		exit 1
	fi
	if [ "$HYGIENE_FAIL2BAN_REFRESH" != "true" ]; then
		warn "fail2ban-ignoreip refresh: skipped (HYGIENE_FAIL2BAN_REFRESH=$HYGIENE_FAIL2BAN_REFRESH) — no weekly range re-resolution"
		if is_systemd && [ -f "$LIVE_ROOT/etc/systemd/system/fail2ban-ignoreip-refresh.timer" ]; then
			systemctl_apply disable --now fail2ban-ignoreip-refresh.timer 2>/dev/null || true
			info "fail2ban-ignoreip refresh timer disabled (unit files left in place; re-enable: HYGIENE_FAIL2BAN_REFRESH=true re-run)"
		fi
	elif ! command -v fail2ban-client >/dev/null 2>&1; then
		warn "fail2ban-ignoreip refresh: deferred — fail2ban not installed on this host (drop-in staged; re-run bootstrap after installing fail2ban)"
	else
		# Generate the weekly refresh helper from THIS file's own functions
		# (single implementation: the helper embeds the fail2ban_*
		# functions verbatim, so it can never drift from the engine).
		mkdir -p "$LIVE_ROOT/usr/local/bin" "$LIVE_ROOT/etc/systemd/system"
		render_fail2ban_ignoreip_refresh_script > "$LIVE_ROOT$FAIL2BAN_REFRESH_SCRIPT.tmp"
		chmod 0755 "$LIVE_ROOT$FAIL2BAN_REFRESH_SCRIPT.tmp"
		bash -n "$LIVE_ROOT$FAIL2BAN_REFRESH_SCRIPT.tmp" || {
			rm -f "$LIVE_ROOT$FAIL2BAN_REFRESH_SCRIPT.tmp"
			error "generated $FAIL2BAN_REFRESH_SCRIPT failed bash -n — aborting"
			exit 1
		}
		mv -f "$LIVE_ROOT$FAIL2BAN_REFRESH_SCRIPT.tmp" "$LIVE_ROOT$FAIL2BAN_REFRESH_SCRIPT"
		info "fail2ban-ignoreip refresh helper written: $FAIL2BAN_REFRESH_SCRIPT"

		hygiene_install "$FAIL2BAN_REFRESH_SERVICE" render_fail2ban_refresh_service 0644
		hygiene_install "$FAIL2BAN_REFRESH_TIMER"   render_fail2ban_refresh_timer 0644
		systemctl_apply daemon-reload
		systemctl_apply enable --now fail2ban-ignoreip-refresh.timer
		info "fail2ban-ignoreip refresh timer installed and enabled (weekly, Persistent=false — reloads only on change)"
	fi
fi


# 6. sysctl forwarding (var-gated; false = do not manage)
# ═══════════════════════════════════════════════════════════════════════
# Writes /etc/sysctl.d/90-host-hygiene-forwarding.conf setting IPv4 + IPv6
# packet forwarding on. Closes the writer gap recorded in linux-desktop-seed
# docs/architecture/host-provisioning.md (§8.3): the L3 gate
# verify-vm-state.sh check 6 asserts `sysctl -n net.ipv4.ip_forward == 1`
# and `net.ipv6.conf.all.forwarding == 1`, but nothing in either repo wrote
# those keys — the assert passed only because something outside both repos
# set them. The keys below match the gate EXACTLY; the drop-in sorts under
# /etc/sysctl.d/ and is applied with `sysctl --system`, then the EFFECTIVE
# values are asserted from /proc/sys (a drop-in file can exist yet be
# shadowed by a later-sorting sysctl.d file, so the file alone proves
# nothing — same shape as the sshd MaxStartups assertion).

# Renders the drop-in. Pure function (stdout) so tests/sysctl-forwarding.bats
# can extract it hermetically without running the engine.
render_sysctl_forwarding() {
	cat <<'EOF'
# IPv4/IPv6 packet forwarding — L1 host hygiene (scripts/host-hygiene.sh section 6).
# Asserted by linux-desktop-seed verify-vm-state.sh check 6
# (net.ipv4.ip_forward=1, net.ipv6.conf.all.forwarding=1).
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
}

SYSCTL_DROP_IN=/etc/sysctl.d/90-host-hygiene-forwarding.conf
# Test seam: HYGIENE_PROC_ROOT overrides the procfs root the effective-value
# assertion reads (default: real /proc → $PROC_ROOT/proc/sys/...).
PROC_ROOT="${HYGIENE_PROC_ROOT:-/}"

info "sysctl forwarding: gate=$HYGIENE_SYSCTL_FORWARDING"
if [ "$HYGIENE_SYSCTL_FORWARDING" != "true" ]; then
	warn "sysctl forwarding disabled — skipping (previously written drop-in stays active)"
else
	if [ -n "$HYGIENE_DRY_RUN" ]; then
		info "DRY RUN: would write $SYSCTL_DROP_IN (mode 0644) and run: sysctl --system; then assert effective net.ipv4.ip_forward + net.ipv6.conf.all.forwarding == 1"
	else
		hygiene_install "$SYSCTL_DROP_IN" render_sysctl_forwarding 0644
		if [ "$MODE" = apply ]; then
			info "sysctl forwarding written: net.ipv4.ip_forward=1, net.ipv6.conf.all.forwarding=1 ($SYSCTL_DROP_IN, mode 0644)"

			# Fail loud, restore nothing silently: apply the drop-in, then
			# assert the effective values the kernel actually holds.
			sysctl --system
			EFFECTIVE_IPV4=$(cat "$PROC_ROOT/proc/sys/net/ipv4/ip_forward" 2>/dev/null || true)
			EFFECTIVE_IPV6=$(cat "$PROC_ROOT/proc/sys/net/ipv6/conf/all/forwarding" 2>/dev/null || true)
			if [ "$EFFECTIVE_IPV4" != "1" ] || [ "$EFFECTIVE_IPV6" != "1" ]; then
				error "sysctl forwarding assertion FAILED: effective net.ipv4.ip_forward='$EFFECTIVE_IPV4', net.ipv6.conf.all.forwarding='$EFFECTIVE_IPV6'; expected both '1' ($SYSCTL_DROP_IN)"
				exit 1
			fi
			info "sysctl forwarding verified: net.ipv4.ip_forward=$EFFECTIVE_IPV4, net.ipv6.conf.all.forwarding=$EFFECTIVE_IPV6 (as configured)"
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

# Returns the reason recorded for a path whose render failed in --check mode
# (HYGIENE_RENDER_FAILS carries "path|reason" lines captured from the render's
# own stderr), or nothing if the path rendered cleanly.
hygiene_check_render_fail_reason() { # $1 = path
	local entry rpath rreason
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		rpath="${entry%%|*}"
		rreason="${entry#*|}"
		if [ "$rpath" = "$1" ]; then
			printf '%s\n' "$rreason"
			return 0
		fi
	done <<< "$HYGIENE_RENDER_FAILS"
	return 1
}

hygiene_check_report() {
	local entry path fn mode rend live ok=0 drift=0 cannot=0 line rline lline reason
	for entry in "${HYGIENE_ARTIFACTS[@]}"; do
		path="${entry%%|*}"
		rest="${entry#*|}"
		fn="${rest%%|*}"
		mode="${rest#*|}"
		rend="$CHECK_TMP$path"
		if [ -n "${HYGIENE_ROOT:-}" ]; then live="$HYGIENE_ROOT/${path#/}"; else live="$path"; fi
		reason="$(hygiene_check_render_fail_reason "$path")"
		if [ -n "$reason" ]; then
			printf 'CANNOT-EVALUATE %s  (%s)\n' "$path" "$reason"
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
