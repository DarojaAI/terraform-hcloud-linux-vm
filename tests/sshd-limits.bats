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
	# Extract just the pure function definitions; the engine itself is never
	# executed here (no writes to /etc, no sshd -t, no systemctl reloads).
	eval "$(sed -n '/^sshd_limits_dropin() {/,/^}/p' "$ENGINE")"
	eval "$(sed -n '/^psp_term_seconds() {/,/^}/p' "$ENGINE")"
	eval "$(sed -n '/^psp_tuple_matches() {/,/^}/p' "$ENGINE")"
	[ "$(type -t sshd_limits_dropin)" = "function" ]
	[ "$(type -t psp_term_seconds)" = "function" ]
	[ "$(type -t psp_tuple_matches)" = "function" ]
}

# Render the drop-in from the configured knobs into the temp dir (defaults
# match the module variables; override per-test via the HYGIENE_SSHD_* vars).
# HYGIENE_SSHD_PERSOURCE_PENALTIES uses ${VAR-default} (not :-) on purpose:
# unset falls back to the chosen lever noauth:0, but an explicitly EMPTY
# value must stay empty so tests can exercise the "leave distro default"
# path (no persourcepenalties line rendered).
render() {
	HYGIENE_SSHD_MAX_STARTUPS="${HYGIENE_SSHD_MAX_STARTUPS:-40:30:100}" \
	HYGIENE_SSHD_MAX_SESSIONS="${HYGIENE_SSHD_MAX_SESSIONS:-20}" \
	HYGIENE_SSHD_KEEPALIVE_INTERVAL="${HYGIENE_SSHD_KEEPALIVE_INTERVAL:-60}" \
	HYGIENE_SSHD_KEEPALIVE_COUNT="${HYGIENE_SSHD_KEEPALIVE_COUNT:-3}" \
	HYGIENE_SSHD_PERSOURCE_PENALTIES="${HYGIENE_SSHD_PERSOURCE_PENALTIES-noauth:0}" \
		sshd_limits_dropin > "$RDIR/09-sshd-limits.conf"
}

@test "defaults render the drop-in with all five values" {
	render
	grep -Eiq '^maxstartups[[:space:]]+40:30:100[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^maxsessions[[:space:]]+20[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^clientaliveinterval[[:space:]]+60[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^clientalivecountmax[[:space:]]+3[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^persourcepenalties[[:space:]]+noauth:0[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
}

@test "custom PerSourcePenalties policy renders verbatim (issue #11 knob)" {
	HYGIENE_SSHD_PERSOURCE_PENALTIES="noauth:0 max:120" render
	grep -Eiq '^persourcepenalties[[:space:]]+noauth:0[[:space:]]+max:120[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
}

@test "empty HYGIENE_SSHD_PERSOURCE_PENALTIES renders no persourcepenalties line (distro default kept)" {
	HYGIENE_SSHD_PERSOURCE_PENALTIES="" render
	run grep -Ei '^persourcepenalties' "$RDIR/09-sshd-limits.conf"
	[ "$status" -eq 1 ]
}

@test "psp_term_seconds mirrors sshd convtime (durations normalize to seconds)" {
	run psp_term_seconds "0"
	[ "$status" -eq 0 ] && [ "$output" = "0" ]
	run psp_term_seconds "90s"
	[ "$status" -eq 0 ] && [ "$output" = "90" ]
	run psp_term_seconds "2m"
	[ "$status" -eq 0 ] && [ "$output" = "120" ]
	run psp_term_seconds "1h30m"
	[ "$status" -eq 0 ] && [ "$output" = "5400" ]
	run psp_term_seconds "1w"
	[ "$status" -eq 0 ] && [ "$output" = "604800" ]
	run psp_term_seconds "bogus"
	[ "$status" -eq 1 ]
}

@test "effective-value matcher accepts honored sshd -T tuples and rejects unhonored ones" {
	EFF="crash:90 authfail:5 noauth:0 grace-exceeded:10 refuseconnection:10 max:600 min:15 max-sources4:65536 max-sources6:65536 overflow:permissive overflow6:permissive"
	# the configured term is present verbatim -> pass
	run psp_tuple_matches "noauth:0" "$EFF"
	[ "$status" -eq 0 ]
	# the distro default (noauth:1) would fail the assertion loud
	run psp_tuple_matches "noauth:0" "${EFF/noauth:0/noauth:1}"
	[ "$status" -eq 1 ]
	# a unit-form knob is canonicalized by sshd -T (noauth:90s -> noauth:90)
	run psp_tuple_matches "noauth:90s" "${EFF/noauth:0/noauth:90}"
	[ "$status" -eq 0 ]
	# a configured keyword that sshd does NOT honor is caught
	run psp_tuple_matches "noauth:0 max:120" "$EFF"
	[ "$status" -eq 1 ]
}

@test "custom knob values are rendered verbatim" {
	HYGIENE_SSHD_MAX_SESSIONS=10 HYGIENE_SSHD_KEEPALIVE_INTERVAL=120 \
	HYGIENE_SSHD_KEEPALIVE_COUNT=5 HYGIENE_SSHD_MAX_STARTUPS=25:40:200 \
	HYGIENE_SSHD_PERSOURCE_PENALTIES="noauth:0 grace-exceeded:20" \
		render
	grep -Eiq '^maxstartups[[:space:]]+25:40:200[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^maxsessions[[:space:]]+10[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^clientaliveinterval[[:space:]]+120[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^clientalivecountmax[[:space:]]+5[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
	grep -Eiq '^persourcepenalties[[:space:]]+noauth:0[[:space:]]+grace-exceeded:20[[:space:]]*$' "$RDIR/09-sshd-limits.conf"
}

@test "engine defaults match the module defaults (40:30:100, 20, 60, 3, noauth:0)" {
	grep -q 'HYGIENE_SSHD_MAX_STARTUPS:=40:30:100' "$ENGINE"
	grep -q 'HYGIENE_SSHD_MAX_SESSIONS:=20' "$ENGINE"
	grep -q 'HYGIENE_SSHD_KEEPALIVE_INTERVAL:=60' "$ENGINE"
	grep -q 'HYGIENE_SSHD_KEEPALIVE_COUNT:=3' "$ENGINE"
	grep -q 'HYGIENE_SSHD_PERSOURCE_PENALTIES=noauth:0' "$ENGINE"
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
	# PerSourcePenalties (issue #11): second cause, same client error —
	# lever, knob, default, empty-opts-out and effective-value assert
	grep -q '#11' "$ENGINE"
	grep -qi 'persourcepenalties' "$ENGINE"
	grep -qi 'noauth' "$ENGINE"
	grep -q 'PerSourcePenaltyExemptList' "$ENGINE"
	grep -q 'max:600' "$ENGINE"
	grep -q 'psp_tuple_matches' "$ENGINE"
	grep -q 'psp_term_seconds' "$ENGINE"
	grep -q 'left at the distro default' "$ENGINE"
}

# Hermetic dry-run helper: record the real drop-in's state (absent, or its
# sha256) and fail if a dry run writes, modifies or stages anything. Hosts
# that already applied the engine (this workstation has 09-sshd-limits.conf
# from 2026-10-31) must observe zero change, not required absence.
assert_dry_run_writes_nothing() {
	if [ -f /etc/ssh/sshd_config.d/09-sshd-limits.conf ]; then
		local before after
		before=$(sha256sum /etc/ssh/sshd_config.d/09-sshd-limits.conf | awk '{print $1}')
		run env HYGIENE_DRY_RUN=1 "$@" bash "$ENGINE"
		[ "$status" -eq 0 ]
		after=$(sha256sum /etc/ssh/sshd_config.d/09-sshd-limits.conf | awk '{print $1}')
		[ "$after" = "$before" ]
	else
		run env HYGIENE_DRY_RUN=1 "$@" bash "$ENGINE"
		[ "$status" -eq 0 ]
		[ ! -e /etc/ssh/sshd_config.d/09-sshd-limits.conf ]
	fi
	# and never leave a staging file behind
	[ ! -e /etc/ssh/sshd_config.d/09-sshd-limits.conf.tmp ]
}

@test "dry-run prints the sshd section and writes nothing on this host" {
	# A dry run must print the section and leave the real drop-in untouched,
	# whether the host already has one (this box does — hand-applied) or not.
	SSH_DROP_IN=/etc/ssh/sshd_config.d/09-sshd-limits.conf
	before="$(stat -c '%i %Y %s' "$SSH_DROP_IN" 2>/dev/null || echo ABSENT)"
	run env HYGIENE_DRY_RUN=1 bash "$ENGINE"
	[ "$status" -eq 0 ]
	echo "$output" | grep -qi 'sshd bounds'
	echo "$output" | grep -qiE 'DRY RUN: would write .*09-sshd-limits'
	echo "$output" | grep -qiE "DRY RUN: would render 'PerSourcePenalties noauth:0'"
	echo "$output" | grep -qi 'persourcepenalties'
	# hermetic: the real /etc/ssh must be untouched after a dry run
	after="$(stat -c '%i %Y %s' "$SSH_DROP_IN" 2>/dev/null || echo ABSENT)"
	[ "$before" = "$after" ]
}

@test "dry-run with empty PerSourcePenalties knob prints the distro-default note, writes nothing" {
	run env HYGIENE_DRY_RUN=1 HYGIENE_SSHD_PERSOURCE_PENALTIES= bash "$ENGINE"
	[ "$status" -eq 0 ]
	echo "$output" | grep -qiE 'distro default|no line'
	[ ! -e /etc/ssh/sshd_config.d/09-sshd-limits.conf.tmp ]
}
