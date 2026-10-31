#!/usr/bin/env bats
# tests/hygiene-check.bats — hermetic self-test for the read-only drift
# detector (`--check`) of scripts/host-hygiene.sh.
#
# Hermetic by design: the comparison runs against a fixture tree under
# HYGIENE_ROOT (the engine's own seam) — the real /etc is never read or
# written, and the engine's system-facing actions (systemctl, sshd, apt,
# journald restart, /opt self-copy) are structurally unreachable in check
# mode. The fixture content is rendered from the engine's OWN pure render
# functions (extracted via sed, exactly like tests/sshd-limits.bats does for
# sshd_limits_dropin), so the fixtures cannot drift from the engine.
#
# The docker-prune section is pinned off (HYGIENE_DOCKER_PRUNE=false) so the
# suite passes identically on hosts with or without docker; docker artifacts
# are exercised live by the engine itself (see the intro of host-hygiene.sh).

setup() {
	ENGINE="$BATS_TEST_DIRNAME/../scripts/host-hygiene.sh"
	[ -f "$ENGINE" ]
	LIVE="$BATS_TEST_TMPDIR/live"
	mkdir -p "$LIVE"
	# Point the live comparison at the hermetic fixture tree (engine seam).
	export HYGIENE_ROOT="$LIVE"
	# Same knobs the engine / module default to, so fixtures match renders.
	export HYGIENE_JOURNALD_MAX_USE=1G
	export HYGIENE_DOCKER_PRUNE=false
	export HYGIENE_DOCKER_PRUNE_UNTIL=168h
	export HYGIENE_UNATTENDED_UPGRADES=true
	export HYGIENE_DISK_ALERT_PCT=85
	export HYGIENE_DISK_WEBHOOK_URL=
	export HYGIENE_SSHD_MAX_STARTUPS=40:30:100
	export HYGIENE_SSHD_MAX_SESSIONS=20
	export HYGIENE_SSHD_KEEPALIVE_INTERVAL=60
	export HYGIENE_SSHD_KEEPALIVE_COUNT=3
	# fail2ban defaults (same as the engine's); the CIDR fixture doubles as
	# the resolved-list cache content AND the drop-in render input.
	export HYGIENE_FAIL2BAN_IGNOREIP=
	export HYGIENE_FAIL2BAN_REFRESH=true
	F2B_CIDR_FIXTURE="140.82.112.0/20 209.99.190.0/24 2603:1020::/47"
	# The engine's own section-6 path vars (renders interpolate them into the
	# unit/comment bytes) — the fixtures must be byte-identical to the
	# engine's renders, so the fixture shell needs the same values.
	FAIL2BAN_JAIL_D=/etc/fail2ban/jail.d
	FAIL2BAN_DROP_IN=$FAIL2BAN_JAIL_D/10-lds-ignoreip.conf
	FAIL2BAN_CACHE=/var/lib/host-hygiene/fail2ban-cidrs.txt
	FAIL2BAN_REFRESH_SCRIPT=/usr/local/bin/fail2ban-ignoreip-refresh.sh
	FAIL2BAN_REFRESH_SERVICE=/etc/systemd/system/fail2ban-ignoreip-refresh.service
	FAIL2BAN_REFRESH_TIMER=/etc/systemd/system/fail2ban-ignoreip-refresh.timer
	# Deterministic refresh gate: a harmless fail2ban-client stubbed on PATH
	# makes the check's refresh-unit gate (command -v) open exactly like on a
	# fail2ban host, so the four fail2ban artifacts are ALWAYS part of the
	# compared surface regardless of this runner's packages. --check never
	# INVOKES the binary (that property is proven with marker-dropping stubs
	# in the last test); command -v only reads PATH.
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat > "$BATS_TEST_TMPDIR/bin/fail2ban-client" <<'EOF'
#!/bin/bash
# presence-only stub: opens the check's refresh gate; never run by --check
exit 0
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/fail2ban-client"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	# Source the engine's pure render functions (never execute the engine):
	# the fixtures are generated from the exact functions --check compares.
	for fn in render_journald_dropin render_apt_auto_upgrades render_apt_unattended \
	          render_host_hygiene_env render_disk_watch_script render_disk_watch_service \
	          render_disk_watch_timer sshd_limits_dropin \
	          fail2ban_cidr_ok fail2ban_fallback_file fail2ban_github_actions \
	          fail2ban_ignoreip_dropin fail2ban_ignoreip_reload fail2ban_ignoreip_apply \
	          fail2ban_refresh_unit render_fail2ban_refresh_service \
	          render_fail2ban_refresh_timer render_fail2ban_ignoreip_refresh_script; do
		eval "$(sed -n "/^${fn}() {/,/^}$/p" "$ENGINE")"
		[ "$(type -t "$fn")" = "function" ]
	done
}

# Relative fixture paths the engine manages when docker-prune is off. The
# test is allowed to know the managed surface — if the engine stops managing
# one of these, the corresponding assertion noise is the point of a test.
seed_fixtures() {
	local rel fn
	# The drop-in render reads FAIL2BAN_CIDRS from a shell variable. Seed it
	# (unexported — the ENGINE child must never inherit it: --check reads the
	# resolved-list cache under HYGIENE_ROOT instead, which is what the
	# cache-absent test manipulates).
	FAIL2BAN_CIDRS="$F2B_CIDR_FIXTURE"
	for spec in \
		"etc/systemd/journald.conf.d/90-host-hygiene.conf|render_journald_dropin" \
		"etc/apt/apt.conf.d/52host-hygiene-auto-upgrades|render_apt_auto_upgrades" \
		"etc/apt/apt.conf.d/52host-hygiene-unattended|render_apt_unattended" \
		"etc/host-hygiene.env|render_host_hygiene_env" \
		"usr/local/bin/host-hygiene-disk-watch.sh|render_disk_watch_script" \
		"etc/systemd/system/disk-watch.service|render_disk_watch_service" \
		"etc/systemd/system/disk-watch.timer|render_disk_watch_timer" \
		"etc/ssh/sshd_config.d/09-sshd-limits.conf|sshd_limits_dropin" \
		"etc/fail2ban/jail.d/10-lds-ignoreip.conf|fail2ban_ignoreip_dropin" \
		"usr/local/bin/fail2ban-ignoreip-refresh.sh|render_fail2ban_ignoreip_refresh_script" \
		"etc/systemd/system/fail2ban-ignoreip-refresh.service|render_fail2ban_refresh_service" \
		"etc/systemd/system/fail2ban-ignoreip-refresh.timer|render_fail2ban_refresh_timer"; do
		rel="${spec%%|*}"
		fn="${spec#*|}"
		mkdir -p "$LIVE/$(dirname "$rel")"
		"$fn" > "$LIVE/$rel"
	done
	# The resolved-list cache is DATA, not a render: apply writes exactly the
	# CIDR list it resolved (one per line); --check reads it back and renders
	# the drop-in from it.
	mkdir -p "$LIVE/var/lib/host-hygiene"
	printf '%s\n' $F2B_CIDR_FIXTURE > "$LIVE/var/lib/host-hygiene/fail2ban-cidrs.txt"
}

@test "clean fixture tree → exit 0, every artifact printed ok" {
	seed_fixtures
	run bash "$ENGINE" --check
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "check: 12 artifacts compared"
	for rel in \
		"/etc/systemd/journald.conf.d/90-host-hygiene.conf" \
		"/etc/apt/apt.conf.d/52host-hygiene-auto-upgrades" \
		"/etc/apt/apt.conf.d/52host-hygiene-unattended" \
		"/etc/host-hygiene.env" \
		"/usr/local/bin/host-hygiene-disk-watch.sh" \
		"/etc/systemd/system/disk-watch.service" \
		"/etc/systemd/system/disk-watch.timer" \
		"/etc/ssh/sshd_config.d/09-sshd-limits.conf" \
		"/etc/fail2ban/jail.d/10-lds-ignoreip.conf" \
		"/usr/local/bin/fail2ban-ignoreip-refresh.sh" \
		"/etc/systemd/system/fail2ban-ignoreip-refresh.service" \
		"/etc/systemd/system/fail2ban-ignoreip-refresh.timer"; do
		echo "$output" | grep -q "^ok       $rel\$" || {
			echo "missing ok line for $rel" >&3
			return 1
		}
	done
	if echo "$output" | grep -qE '^DRIFT'; then
		echo "UNEXPECTED DRIFT: $(echo "$output" | grep -E '^DRIFT')" >&3
		return 1
	fi
	if echo "$output" | grep -qE '^CANNOT-EVALUATE'; then
		echo "UNEXPECTED CANNOT: $(echo "$output" | grep -E '^CANNOT-EVALUATE')" >&3
		return 1
	fi
}

@test "one differing artifact → exit 1 with path and first differing line" {
	seed_fixtures
	# Hand-edit one managed file, the way drift happens in the wild: append a
	# foreign CIDR to the fail2ban jail drop-in's ignoreip line. The engine's
	# register/render machinery must pick the fail2ban artifact up too and
	# report the exact differing line (path + live-vs-engine bytes).
	sed -i 's|2603:1020::/47|2603:1020::/47 2001:db8::/32|' "$LIVE/etc/fail2ban/jail.d/10-lds-ignoreip.conf"
	run bash "$ENGINE" --check
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "DRIFT    /etc/fail2ban/jail.d/10-lds-ignoreip.conf"
	echo "$output" | grep -qE 'differs at line [0-9]+: live ".*2001:db8::/32.*" vs engine ".*"'
	echo "$output" | grep -q "check: 12 artifacts compared"
}

@test "missing artifact → exit 1 drift; absent fail2ban cache → exit 2 cannot-evaluate" {
	seed_fixtures
	rm -f "$LIVE/etc/ssh/sshd_config.d/09-sshd-limits.conf"
	run bash "$ENGINE" --check
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "DRIFT    /etc/ssh/sshd_config.d/09-sshd-limits.conf  (missing on live host)"
	echo "$output" | grep -q "check: 12 artifacts compared"

	# Without the resolved-list cache the jail drop-in cannot be evaluated:
	# its expected content is unknowable, and --check must neither fetch nor
	# write. Loud CANNOT-EVALUATE + exit 2 (never a silent pass).
	rm -f "$LIVE/var/lib/host-hygiene/fail2ban-cidrs.txt"
	run bash "$ENGINE" --check
	[ "$status" -eq 2 ]
	echo "$output" | grep -q "CANNOT-EVALUATE /etc/fail2ban/jail.d/10-lds-ignoreip.conf"
	echo "$output" | grep -qE 'resolved-list cache missing'
}

@test "unreadable live artifact → exit 2 with path, not a silent skip" {
	# Build a SECOND fixture root in a world-traversable location: bats' own
	# temp dir lives under an 0700 parent that an unprivileged user cannot
	# enter, which would mask the read-only-check semantics we assert here.
	FAKE_ROOT="${TMPDIR:-/tmp}/host-hygiene-unreadable-$$"
	rm -rf "$FAKE_ROOT"
	mkdir -p "$FAKE_ROOT"
	OLD_LIVE="$LIVE"
	LIVE="$FAKE_ROOT"
	seed_fixtures
	chmod -R a+rX "$FAKE_ROOT"
	chmod 000 "$FAKE_ROOT/etc/systemd/journald.conf.d/90-host-hygiene.conf"
	LIVE="$OLD_LIVE"
	# HYGIENE_FAIL2BAN_REFRESH=false keeps the fail2ban refresh trio out of
	# the compared surface here: the nobody droppriv variant cannot traverse
	# bats' 0700 temp stub dir, so its refresh gate would differ — pinning the
	# knob makes the 9-artifact count identical for every privilege variant.
	if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null 2>&1; then
		# As root, chmod 000 is still readable — drop privileges so the
		# unreadable-file path is genuinely exercised (the check itself must
		# work without root).
		run runuser -u nobody -- env HOME="$BATS_TEST_TMPDIR" HYGIENE_ROOT="$FAKE_ROOT" \
			HYGIENE_FAIL2BAN_REFRESH=false bash "$ENGINE" --check
	elif [ "$(id -u)" = 0 ]; then
		skip "root without runuser — cannot simulate unprivileged read"
	else
		run env HYGIENE_ROOT="$FAKE_ROOT" HYGIENE_FAIL2BAN_REFRESH=false bash "$ENGINE" --check
	fi
	rm -rf "$FAKE_ROOT"
	[ "$status" -eq 2 ]
	echo "$output" | grep -q "CANNOT-EVALUATE /etc/systemd/journald.conf.d/90-host-hygiene.conf  (live file not readable)"
	# everything else still evaluated (9 = 8 standard + the fail2ban drop-in,
	# which renders ok from its seeded cache; the refresh trio is
	# refresh-gated off above)
	echo "$output" | grep -q "check: 9 artifacts compared"
}

@test "--check writes nothing: live fixtures bit-identical (inode, mtime, mode)" {
	seed_fixtures
	snapshot() {
		find "$LIVE" \( -type f -o -type d \) -exec stat -c '%i|%Y|%a|%n' {} + | LC_ALL=C sort
	}
	before="$(snapshot)"
	run bash "$ENGINE" --check
	[ "$status" -eq 0 ]
	after="$(snapshot)"
	[ "$before" = "$after" ]
	# and the engine's own temp dir is cleaned up afterwards
	run bash -c 'ls -d "${TMPDIR:-/tmp}"/host-hygiene-check.* 2>/dev/null | wc -l'
	[ "$output" = "0" ]
}

@test "--check never invokes systemctl, sshd, curl, wget or fail2ban-client" {
	seed_fixtures
	STUB="$BATS_TEST_TMPDIR/stubs"
	mkdir -p "$STUB"
	# Every apply-side binary the fail2ban/docker/journald sections could
	# reach: if --check slipped into apply machinery it would trip one of
	# these (exit 99) and leave a marker. The fail2ban-client stub here also
	# shadows the setup() presence stub, so the refresh gate still opens.
	for b in systemctl sshd curl wget fail2ban-client; do
		cat > "$STUB/$b" <<EOF
#!/bin/bash
echo "invoked $b" >> "$STUB/marker"
exit 99
EOF
		chmod +x "$STUB/$b"
	done
	run env PATH="$STUB:$PATH" bash "$ENGINE" --check
	[ "$status" -eq 0 ]
	[ ! -e "$STUB/marker" ]
	# engines that reach apply machinery would trip the stubs
	! grep -q "invoked" "$STUB/marker" 2>/dev/null
}
