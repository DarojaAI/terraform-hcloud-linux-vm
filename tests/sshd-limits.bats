#!/usr/bin/env bats
# tests/sshd-limits.bats — hermetic self-test for the sshd connection-bounds
# section (5) of scripts/host-hygiene.sh.
#
# Hermetic by design: everything is rendered into a BATS temp dir; the real
# /etc/ssh is never read or written. The test sources ONLY the pure render
# function `sshd_limits_dropin()` (plus nothing else) out of the engine, so
# the asserted drop-in content is the engine's single source of truth — the
# test reproduces the exact render the engine ships and cannot drift from it.

setup() {
	ENGINE="$BATS_TEST_DIRNAME/../scripts/host-hygiene.sh"
	[ -f "$ENGINE" ]
	RDIR="$BATS_TEST_TMPDIR/etc/ssh/sshd_config.d"
	mkdir -p "$RDIR"
	# Extract just the render function definition; the engine itself is never
	# executed here (no writes to /etc, no sshd -t, no systemctl reloads).
	eval "$(sed -n '/^sshd_limits_dropin() {/,/^}/p' "$ENGINE")"
	[ "$(type -t sshd_limits_dropin)" = "function" ]
}

# Render the drop-in from the configured knobs into the temp dir (defaults
# match the module variables; override per-test via the HYGIENE_SSHD_* vars).
render() {
	HYGIENE_SSHD_MAX_STARTUPS="${HYGIENE_SSHD_MAX_STARTUPS:-40:30:100}" \
	HYGIENE_SSHD_MAX_SESSIONS="${HYGIENE_SSHD_MAX_SESSIONS:-20}" \
	HYGIENE_SSHD_KEEPALIVE_INTERVAL="${HYGIENE_SSHD_KEEPALIVE_INTERVAL:-60}" \
	HYGIENE_SSHD_KEEPALIVE_COUNT="${HYGIENE_SSHD_KEEPALIVE_COUNT:-3}" \
		sshd_limits_dropin > "$RDIR/09-sshd-limits.conf"
}

@test "defaults render the drop-in with all four values" {
	render
	grep -Eiq '^maxstartups[[:space:]]+40:30:100[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^maxsessions[[:space:]]+20[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^clientaliveinterval[[:space:]]+60[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^clientalivecountmax[[:space:]]+3[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
}

@test "custom knob values are rendered verbatim" {
	HYGIENE_SSHD_MAX_SESSIONS=10 HYGIENE_SSHD_KEEPALIVE_INTERVAL=120 \
	HYGIENE_SSHD_KEEPALIVE_COUNT=5 HYGIENE_SSHD_MAX_STARTUPS=25:40:200 \
		render
	grep -Eiq '^maxstartups[[:space:]]+25:40:200[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^maxsessions[[:space:]]+10[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^clientaliveinterval[[:space:]]+120[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^clientalivecountmax[[:space:]]+5[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
}

@test "engine defaults match the module defaults (40:30:100, 20, 60, 3)" {
	grep -q 'HYGIENE_SSHD_MAX_STARTUPS:=40:30:100' "$ENGINE"
	grep -q 'HYGIENE_SSHD_MAX_SESSIONS:=20' "$ENGINE"
	grep -q 'HYGIENE_SSHD_KEEPALIVE_INTERVAL:=60' "$ENGINE"
	grep -q 'HYGIENE_SSHD_KEEPALIVE_COUNT:=3' "$ENGINE"
}

@test "09-sshd-limits.conf sorts before the legacy 10-l2.conf" {
	# sshd's Include sits at the top of sshd_config and keeps the FIRST value
	# it reads, so the earlier-sorting drop-in shadows the later one.
	run bash -c "printf '%s\n' '10-l2.conf' '09-sshd-limits.conf' | LC_ALL=C sort"
	[ "${lines[0]}" = "09-sshd-limits.conf" ]
	[ "${lines[1]}" = "10-l2.conf" ]
	# both filenames are what the engine actually writes/renames
	grep -q '09-sshd-limits.conf' "$ENGINE"
	grep -q '10-l2.conf' "$ENGINE"
}

@test "rationale, evidence, migration and gate are wired into the engine" {
	# sort-first rationale with evidence (issue #9)
	grep -qi 'Include' "$ENGINE"
	grep -qi 'first value' "$ENGINE"
	grep -qi '3:50:10' "$ENGINE"
	grep -q 'kex_exchange_identification' "$ENGINE"
	grep -q 'Connection reset by peer' "$ENGINE"
	# legacy migration: rename (never delete) only when 3:50:10 is present
	grep -qi 'maxstartups[[:space:]]*3:50:10' "$ENGINE"
	grep -q 'disabled-' "$ENGINE"
	# mode and gate per the brief
	grep -q 'chmod 0644' "$ENGINE"
	grep -q 'HYGIENE_SSHD_MAX_STARTUPS.*0' "$ENGINE"
}

@test "dry-run prints the sshd section and writes nothing on this host" {
	run env HYGIENE_DRY_RUN=1 bash "$ENGINE"
	[ "$status" -eq 0 ]
	echo "$output" | grep -qi 'sshd bounds'
	echo "$output" | grep -qiE 'DRY RUN: would write .*09-sshd-limits'
	# hermetic: the real /etc/ssh must be untouched after a dry run
	[ ! -e /etc/ssh/sshd_config.d/09-sshd-limits.conf ]
}
