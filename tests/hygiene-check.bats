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
	# Source the engine's pure render functions (never execute the engine):
	# the fixtures are generated from the exact functions --check compares.
	for fn in render_journald_dropin render_apt_auto_upgrades render_apt_unattended \
	          render_host_hygiene_env render_disk_watch_script render_disk_watch_service \
	          render_disk_watch_timer sshd_limits_dropin; do
		eval "$(sed -n "/^${fn}() {/,/^}$/p" "$ENGINE")"
		[ "$(type -t "$fn")" = "function" ]
	done
}

# Relative fixture paths the engine manages when docker-prune is off. The
# test is allowed to know the managed surface — if the engine stops managing
# one of these, the corresponding assertion noise is the point of a test.
seed_fixtures() {
	local rel fn
	for spec in \
		"etc/systemd/journald.conf.d/90-host-hygiene.conf|render_journald_dropin" \
		"etc/apt/apt.conf.d/52host-hygiene-auto-upgrades|render_apt_auto_upgrades" \
		"etc/apt/apt.conf.d/52host-hygiene-unattended|render_apt_unattended" \
		"etc/host-hygiene.env|render_host_hygiene_env" \
		"usr/local/bin/host-hygiene-disk-watch.sh|render_disk_watch_script" \
		"etc/systemd/system/disk-watch.service|render_disk_watch_service" \
		"etc/systemd/system/disk-watch.timer|render_disk_watch_timer" \
		"etc/ssh/sshd_config.d/09-sshd-limits.conf|sshd_limits_dropin"; do
		rel="${spec%%|*}"
		fn="${spec#*|}"
		mkdir -p "$LIVE/$(dirname "$rel")"
		"$fn" > "$LIVE/$rel"
	done
}

@test "clean fixture tree → exit 0, every artifact printed ok" {
	seed_fixtures
	run bash "$ENGINE" --check
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "check: 8 artifacts compared"
	for rel in \
		"/etc/systemd/journald.conf.d/90-host-hygiene.conf" \
		"/etc/apt/apt.conf.d/52host-hygiene-auto-upgrades" \
		"/etc/apt/apt.conf.d/52host-hygiene-unattended" \
		"/etc/host-hygiene.env" \
		"/usr/local/bin/host-hygiene-disk-watch.sh" \
		"/etc/systemd/system/disk-watch.service" \
		"/etc/systemd/system/disk-watch.timer" \
		"/etc/ssh/sshd_config.d/09-sshd-limits.conf"; do
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
	# Hand-edit one managed file, the way drift happens in the wild.
	printf '[Journal]\nSystemMaxUse=2G\n' > "$LIVE/etc/systemd/journald.conf.d/90-host-hygiene.conf"
	run bash "$ENGINE" --check
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "DRIFT    /etc/systemd/journald.conf.d/90-host-hygiene.conf"
	echo "$output" | grep -q "differs at line 2"
	echo "$output" | grep -q 'live "SystemMaxUse=2G" vs engine "SystemMaxUse=1G"'
	echo "$output" | grep -q "check: 8 artifacts compared"
}

@test "one missing artifact → exit 1 with path" {
	seed_fixtures
	rm -f "$LIVE/etc/ssh/sshd_config.d/09-sshd-limits.conf"
	run bash "$ENGINE" --check
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "DRIFT    /etc/ssh/sshd_config.d/09-sshd-limits.conf  (missing on live host)"
	echo "$output" | grep -q "check: 8 artifacts compared"
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
	if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null 2>&1; then
		# As root, chmod 000 is still readable — drop privileges so the
		# unreadable-file path is genuinely exercised (the check itself must
		# work without root).
		run runuser -u nobody -- env HOME="$BATS_TEST_TMPDIR" HYGIENE_ROOT="$FAKE_ROOT" \
			bash "$ENGINE" --check
	elif [ "$(id -u)" = 0 ]; then
		skip "root without runuser — cannot simulate unprivileged read"
	else
		run env HYGIENE_ROOT="$FAKE_ROOT" bash "$ENGINE" --check
	fi
	rm -rf "$FAKE_ROOT"
	[ "$status" -eq 2 ]
	echo "$output" | grep -q "CANNOT-EVALUATE /etc/systemd/journald.conf.d/90-host-hygiene.conf  (live file not readable)"
	# everything else still evaluated
	echo "$output" | grep -q "check: 8 artifacts compared"
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

@test "--check never invokes systemctl or sshd" {
	seed_fixtures
	STUB="$BATS_TEST_TMPDIR/stubs"
	mkdir -p "$STUB"
	for b in systemctl sshd; do
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
	# engines that reach apply machinery would trip both stubs
	! grep -q "invoked" "$STUB/marker" 2>/dev/null
}
