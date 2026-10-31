#!/usr/bin/env bats
# tests/fail2ban-ignoreip.bats — hermetic self-test for the fail2ban sshd
# ignoreip section (6) of scripts/host-hygiene.sh.
#
# Hermetic by design: every drop-in/unit is rendered or applied under a BATS
# temp root with FAKE curl/wget/fail2ban-client/systemctl on PATH — the real
# /etc/fail2ban, /etc/systemd/system and /usr/local/bin are never read or
# written. The tests eval ONLY the section-6 functions out of the engine
# (plus a small static-fallback fixture, since the real data file is data,
# not code), so the asserted drop-in content is the engine's single source of
# truth and cannot drift from it. The live-fetch path is exercised with a
# fake curl so the fetch->parse->normalise logic itself is proven.

bats_require_minimum_version 1.5.0  # run --separate-stderr

setup() {
	ENGINE="$BATS_TEST_DIRNAME/../scripts/host-hygiene.sh"
	[ -f "$ENGINE" ]

	ROOT="$BATS_TEST_TMPDIR/fakeroot"
	F2B_JAIL="$ROOT/etc/fail2ban/jail.d"
	F2B_LOG="$BATS_TEST_TMPDIR/fake-calls.log"
	mkdir -p "$F2B_JAIL" "$BATS_TEST_TMPDIR/bin"

	# Static fallback fixture (the real engine falls back to
	# etc/fail2ban/github-actions-cidrs.txt; here we point the engine's
	# override knob at a small deterministic copy so tests never hit the
	# network or depend on the repo data blob).
	FALLBACK_FIXTURE="$BATS_TEST_TMPDIR/github-actions-cidrs.txt"
	cat > "$FALLBACK_FIXTURE" <<'EOF'
# fixture — source: api.github.com/meta -> "actions" (captured 2026-10-31)
140.82.112.0/20
209.99.190.0/24
2603:1020::/47
EOF
	export HYGIENE_FAIL2BAN_FALLBACK_FILE="$FALLBACK_FIXTURE"

	# Fakes on PATH: curl/wget ALWAYS fail by default (tests that need the
	# live path replace the curl fake), so the resolver deterministically
	# takes the fallback file (no network, no 10s hangs); fail2ban-client -t
	# succeeds; systemctl answers is-active for fail2ban and records every
	# call in the log so the tests can prove reloads happen only on change.
	cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/bin/bash
echo "curl: forced offline (test)" >&2
exit 1
EOF
	cat > "$BATS_TEST_TMPDIR/bin/wget" <<'EOF'
#!/bin/bash
echo "wget: forced offline (test)" >&2
exit 1
EOF
	cat > "$BATS_TEST_TMPDIR/bin/fail2ban-client" <<EOF
#!/bin/bash
echo "fail2ban-client \$*" >> "$F2B_LOG"
[ "\$1" = "-t" ] && exit 0
exit 0
EOF
	cat > "$BATS_TEST_TMPDIR/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$F2B_LOG"
if [ "\$1" = "-q" ] && [ "\$2" = "is-active" ] && [ "\$3" = "fail2ban" ]; then
	exit 0
fi
[ "\$1" = "reload" ] && exit 0
exit 0
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin"/*
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

	# Extract ONLY the section-6 pure functions. The engine itself is never
	# executed until the engine-level tests explicitly run it in dry-run.
	local fn
	for fn in fail2ban_cidr_ok fail2ban_fallback_file fail2ban_github_actions \
	          fail2ban_ignoreip_dropin fail2ban_ignoreip_reload \
	          fail2ban_ignoreip_apply fail2ban_refresh_unit; do
		eval "$(sed -n "/^${fn}() {/,/^}/p" "$ENGINE")"
		[ "$(type -t "$fn")" = "function" ]
	done

	# Minimal log helpers the extracted functions call at runtime.
	info()  { echo "[INFO] $1"; }
	warn()  { echo "[WARN] $1" >&2; }
	error() { echo "[ERROR] $1" >&2; }

	# The engine's section-6 paths are absolute; the extracted functions read
	# them at CALL time, so pointing them at the temp root keeps everything
	# hermetic while exercising the real apply mechanics (tmp, chmod, cmp,
	# mv, reload gate).
	FAIL2BAN_JAIL_D="$F2B_JAIL"
	FAIL2BAN_DROP_IN="$F2B_JAIL/10-lds-ignoreip.conf"
	FAIL2BAN_REFRESH_SCRIPT="$ROOT/usr/local/bin/fail2ban-ignoreip-refresh.sh"
	FAIL2BAN_REFRESH_SERVICE="$ROOT/etc/systemd/system/fail2ban-ignoreip-refresh.service"
	FAIL2BAN_REFRESH_TIMER="$ROOT/etc/systemd/system/fail2ban-ignoreip-refresh.timer"
	FAIL2BAN_CACHE="$ROOT/var/lib/host-hygiene/fail2ban-cidrs.txt"
}

FIXTURE_CIDRS="140.82.112.0/20 209.99.190.0/24 2603:1020::/47"

render() {
	FAIL2BAN_CIDRS="$FIXTURE_CIDRS" \
		HYGIENE_FAIL2BAN_IGNOREIP="${HYGIENE_FAIL2BAN_IGNOREIP:-}" \
		fail2ban_ignoreip_dropin > "$1"
}

@test "drop-in renders [sshd], loopback and the static fallback file when the fetch fails" {
	local f="$F2B_JAIL/render-test.conf"
	render "$f"
	grep -q '^\[sshd\]' "$f"
	grep -q '^ignoreip = 127.0.0.1/8 ::1' "$f"
	# every fallback-file CIDR must have survived into the ignoreip line
	local cidr
	for cidr in $FIXTURE_CIDRS; do
		grep -Fq "$cidr" "$f"
	done
	local rendered expected
	rendered=$(grep -oE '[0-9a-fA-F:]+/[0-9]+' "$f" | wc -l)
	expected=$(printf '%s ' $FIXTURE_CIDRS | wc -w)
	# rendered = fallback CIDRs + the explicit loopback 127.0.0.1/8 (::1 has
	# no slash so it does not match the counting regex)
	[ "$rendered" -eq $((expected + 1)) ]
	# the drop-in documents its snapshot provenance
	grep -q '2026-10-31' "$f"
}

@test "resolver falls back to the static fallback file exactly when the fetch fails" {
	# --separate-stderr: the resolver logs a WARN to stderr; stdout must be
	# exactly the file's CIDR list (what the drop-in writer captures).
	run --separate-stderr fail2ban_github_actions
	[ "$status" -eq 0 ]
	[ "$output" = "$FIXTURE_CIDRS" ]
	echo "$stderr" | grep -qi 'static fallback'
}

@test "live meta parse (fake curl) normalises: top-level actions, invalid dropped" {
	cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/bin/bash
cat <<'JSON'
{"actions":["140.82.112.0/20","not-a-cidr","2603:1020::/47"],"domains":{"actions":["9.9.9.9/32"]}}
JSON
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/curl"
	run --separate-stderr fail2ban_github_actions
	[ "$status" -eq 0 ]
	# top-level .actions only (the nested domains.actions block must be cut),
	# malformed token dropped, the rest normalised to a clean space list
	[ "$output" = "140.82.112.0/20 2603:1020::/47" ]
	echo "$stderr" | grep -qi 'dropped 1'
}

@test "live meta parse falls back to the text parser when jq fails (same normalisation)" {
	# fake jq that always fails: jq path yields nothing -> text parser runs
	cat > "$BATS_TEST_TMPDIR/bin/jq" <<'EOF'
#!/bin/bash
exit 127
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/jq"
	cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/bin/bash
cat <<'JSON'
{"actions":["140.82.112.0/20","not-a-cidr","2603:1020::/47"],"domains":{"actions":["9.9.9.9/32"]}}
JSON
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/curl"
	run --separate-stderr fail2ban_github_actions
	[ "$status" -eq 0 ]
	[ "$output" = "140.82.112.0/20 2603:1020::/47" ]
	echo "$stderr" | grep -qi 'dropped 1'
}

@test "custom HYGIENE_FAIL2BAN_IGNOREIP CIDRs are appended to the ignoreip line" {
	local f="$BATS_TEST_TMPDIR/extra.conf"
	HYGIENE_FAIL2BAN_IGNOREIP="203.0.113.0/24 2001:db8::/32" render "$f"
	grep -Fq '203.0.113.0/24' "$f"
	grep -Fq '2001:db8::/32' "$f"
}

@test "rendering is idempotent — two runs produce byte-identical output" {
	HYGIENE_FAIL2BAN_IGNOREIP="203.0.113.0/24" render "$BATS_TEST_TMPDIR/render1"
	HYGIENE_FAIL2BAN_IGNOREIP="203.0.113.0/24" render "$BATS_TEST_TMPDIR/render2"
	cmp "$BATS_TEST_TMPDIR/render1" "$BATS_TEST_TMPDIR/render2"
}

@test "apply validates once and reloads fail2ban only when the drop-in changed" {
	fail2ban_ignoreip_apply    # first run: writes + validates + reloads
	fail2ban_ignoreip_apply    # second run: byte-identical -> no reload
	[ -f "$FAIL2BAN_DROP_IN" ]
	[ "$(stat -c %a "$FAIL2BAN_DROP_IN")" = "644" ]
	grep -q '^\[sshd\]' "$FAIL2BAN_DROP_IN"
	# apply persists the resolved list into the cache (one CIDR per line) —
	# the deterministic input --check renders the drop-in from
	[ -f "$FAIL2BAN_CACHE" ]
	[ "$(tr -d '[:space:]' < "$FAIL2BAN_CACHE")" = "$(printf '%s' "$FIXTURE_CIDRS" | tr -d '[:space:]')" ]
	local validations reloads
	validations=$(grep -c 'fail2ban-client' "$F2B_LOG")
	[ "$validations" -eq 1 ]
	reloads=$(grep -c 'systemctl reload fail2ban' "$F2B_LOG")
	[ "$reloads" -eq 1 ]
}

@test "refresh unit renders the same-writer service and a weekly Persistent=false timer" {
	local svc="$BATS_TEST_TMPDIR/refresh.service"
	local tmr="$BATS_TEST_TMPDIR/refresh.timer"
	fail2ban_refresh_unit service > "$svc"
	fail2ban_refresh_unit timer   > "$tmr"
	grep -q '^ExecStart=' "$svc"
	grep -q 'fail2ban-ignoreip-refresh.sh' "$svc"
	grep -q '^\[Unit\]' "$tmr"
	grep -q '^OnCalendar=weekly' "$tmr"
	grep -q '^Persistent=false' "$tmr"
	grep -q '^\[Install\]' "$tmr"
}

@test "missing fallback file -> resolver fails, apply skips the write loudly" {
	local missing="$BATS_TEST_TMPDIR/does-not-exist.txt"
	# run + env can't see bash functions — export instead (each test gets a
	# fresh setup, so overrides never leak)
	HYGIENE_FAIL2BAN_FALLBACK_FILE="$missing" run --separate-stderr fail2ban_github_actions
	[ "$status" -ne 0 ]
	[ -z "$output" ]
	echo "$stderr" | grep -qi 'refusing'
	# apply must NOT create the drop-in or the cache and must return non-zero
	HYGIENE_FAIL2BAN_FALLBACK_FILE="$missing" run fail2ban_ignoreip_apply
	[ "$status" -ne 0 ]
	[ ! -e "$FAIL2BAN_DROP_IN" ]
	[ ! -e "$FAIL2BAN_CACHE" ]
}

@test "malformed line in fallback file rejects the file (never a partial exemption)" {
	local bad="$BATS_TEST_TMPDIR/bad.txt"
	printf '# header\n140.82.112.0/20\n209.99.190.0/24\nnot-a-cidr\n' > "$bad"
	HYGIENE_FAIL2BAN_FALLBACK_FILE="$bad" run --separate-stderr fail2ban_github_actions
	[ "$status" -ne 0 ]
	[ -z "$output" ]
	echo "$stderr" | grep -qi 'malformed'
	HYGIENE_FAIL2BAN_FALLBACK_FILE="$bad" run fail2ban_ignoreip_apply
	[ "$status" -ne 0 ]
	[ ! -e "$FAIL2BAN_DROP_IN" ]
}

@test "engine dry-run with HYGIENE_FAIL2BAN_REFRESH=false skips the refresh unit" {
	run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
		HYGIENE_DRY_RUN=1 HYGIENE_FAIL2BAN_REFRESH=false bash "$ENGINE"
	[ "$status" -eq 0 ]
	echo "$output" | grep -qi 'fail2ban-ignoreip'
	echo "$output" | grep -qi 'refresh unit skipped'
}

@test "engine dry-run with unresolvable ranges exits non-zero and prints why" {
	run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HYGIENE_DRY_RUN=1 \
		HYGIENE_FAIL2BAN_FALLBACK_FILE="$BATS_TEST_TMPDIR/does-not-exist.txt" bash "$ENGINE"
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi 'fail2ban-ignoreip'
	echo "$output" | grep -qi 'skipping the drop-in write'
}

@test "dry-run prints the rendered drop-in and writes NOTHING on this host" {
	run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HYGIENE_DRY_RUN=1 bash "$ENGINE"
	[ "$status" -eq 0 ]
	echo "$output" | grep -qi 'fail2ban-ignoreip'
	echo "$output" | grep -qiE 'DRY RUN: would write .*10-lds-ignoreip'
	[ ! -e /etc/fail2ban/jail.d/10-lds-ignoreip.conf ]
	[ ! -e /etc/systemd/system/fail2ban-ignoreip-refresh.service ]
	[ ! -e /etc/systemd/system/fail2ban-ignoreip-refresh.timer ]
	[ ! -e /usr/local/bin/fail2ban-ignoreip-refresh.sh ]
	[ ! -e /opt/github-actions-cidrs.txt ]
	[ ! -e /var/lib/host-hygiene/fail2ban-cidrs.txt ]
}

@test "rationale, evidence, parser, fallback file and gates are wired into the engine" {
	grep -qi 'issue #10' "$ENGINE"
	grep -qiE '4.182.219.135|209.99.190.215' "$ENGINE"
	grep -q 'api.github.com/meta' "$ENGINE"
	grep -q '"actions"' "$ENGINE"
	grep -q '"hooks"' "$ENGINE"
	grep -q 'github-actions-cidrs.txt' "$ENGINE"
	grep -q 'HYGIENE_FAIL2BAN_FALLBACK_FILE' "$ENGINE"
	grep -q 'fail2ban_cidr_ok' "$ENGINE"
	grep -q 'Persistent=false' "$ENGINE"
	grep -q 'fail2ban-client -t' "$ENGINE"
	grep -q 'cmp -s' "$ENGINE"
	grep -q 'HYGIENE_FAIL2BAN_IGNOREIP' "$ENGINE"
	grep -q 'HYGIENE_FAIL2BAN_REFRESH' "$ENGINE"
}
