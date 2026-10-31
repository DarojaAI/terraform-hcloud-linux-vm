#!/usr/bin/env bats
# tests/sysctl-forwarding.bats — hermetic self-test for the sysctl forwarding
# section (6) of scripts/host-hygiene.sh.
#
# Hermetic by design: the APPLY path runs under HYGIENE_ROOT (fixture tree
# for every write, incl. the canonical self-copy) and HYGIENE_PROC_ROOT
# (fixture proc tree that the stubbed `sysctl` writes), with systemctl/sshd/
# apt-get/sysctl stubbed on PATH — nothing touches the real /etc, /proc/sys,
# /opt, or any real service or package manager. The CHECK path uses the
# engine's own HYGIENE_ROOT seam, exactly like tests/hygiene-check.bats.

setup() {
	ENGINE="$BATS_TEST_DIRNAME/../scripts/host-hygiene.sh"
	[ -f "$ENGINE" ]
	LIVE="$BATS_TEST_TMPDIR/live"
	mkdir -p "$LIVE"
	export HYGIENE_ROOT="$LIVE"
	# The stubbed `sysctl --system` writes the effective values here
	# ($HYGIENE_PROC_ROOT/proc/sys/... mirrors the real /proc/sys/...); the
	# engine's assertion reads them back from the same fixture tree.
	export HYGIENE_PROC_ROOT="$LIVE"
	mkdir -p "$HYGIENE_PROC_ROOT"
	# Same knobs the engine / module default to, so fixture renders match.
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
	export HYGIENE_SYSCTL_FORWARDING=true
	# PATH stubs so apply mode can never reach a real service, package
	# manager, or the real sysctl. sshd must report the effective MaxStartups
	# the engine asserts (like the real `sshd -T` would on the configured
	# host), or the earlier sshd section would fail the run before section 6.
	STUB="$BATS_TEST_TMPDIR/stubs"
	mkdir -p "$STUB"
	for b in systemctl apt-get; do
		cat > "$STUB/$b" <<'STUB'
#!/bin/bash
exit 0
STUB
		chmod +x "$STUB/$b"
	done
	cat > "$STUB/sshd" <<'STUB'
#!/bin/bash
# no-op daemon: report the effective bounds, validate nothing. Both sections
# assert against `sshd -T`: the earlier sshd section (MaxStartups) and the
# PerSourcePenalties assertion added in #11 — the stub has to report the
# policy the drop-in configured, exactly like the real daemon would.
echo "maxstartups 40:30:100"
echo "persourcepenalties noauth:0"
exit 0
STUB
	chmod +x "$STUB/sshd"
	cat > "$STUB/sysctl" <<'STUB'
#!/bin/bash
# stub of `sysctl --system`: applies the drop-in by writing the effective
# values into the fixture proc tree (modelling what the real sysctl does),
# and logs the invocation so tests can prove when (and when not) it ran.
ROOT="${HYGIENE_PROC_ROOT:?}"
mkdir -p "$ROOT/proc/sys/net/ipv4" "$ROOT/proc/sys/net/ipv6/conf/all"
printf '1\n' > "$ROOT/proc/sys/net/ipv4/ip_forward"
printf '1\n' > "$ROOT/proc/sys/net/ipv6/conf/all/forwarding"
printf 'sysctl --system\n' >> "$ROOT/sysctl.invocations"
exit 0
STUB
	chmod +x "$STUB/sysctl"
	export PATH="$STUB:$PATH"
}

@test "renders both forwarding keys the L3 gate asserts; module wiring is threaded" {
	# Render the engine's own pure function, exactly like sshd-limits.bats
	# extracts sshd_limits_dropin — content cannot drift from the engine.
	eval "$(sed -n '/^render_sysctl_forwarding() {/,/^}$/p' "$ENGINE")"
	[ "$(type -t render_sysctl_forwarding)" = "function" ]
	run render_sysctl_forwarding
	[ "$status" -eq 0 ]
	echo "$output" | grep -q '^net\.ipv4\.ip_forward=1$'
	echo "$output" | grep -q '^net\.ipv6\.conf\.all\.forwarding=1$'
	# the engine wires knob default, drop-in path, apply + effective assert
	grep -q 'HYGIENE_SYSCTL_FORWARDING:=true' "$ENGINE"
	grep -q '90-host-hygiene-forwarding.conf' "$ENGINE"
	grep -q 'sysctl --system' "$ENGINE"
	grep -q 'proc/sys/net/ipv4/ip_forward' "$ENGINE"
	grep -q 'proc/sys/net/ipv6/conf/all/forwarding' "$ENGINE"
	# the module threads the same knob: variables.tf -> main.tf -> first-boot.sh
	grep -q '"sysctl_forwarding"' "$BATS_TEST_DIRNAME/../variables.tf"
	grep -q 'tostring(var.sysctl_forwarding)' "$BATS_TEST_DIRNAME/../main.tf"
	grep -q 'hygiene_sysctl_forwarding' "$BATS_TEST_DIRNAME/../scripts/first-boot.sh"
}

@test "apply: idempotent against a fixture root; effective values asserted from the proc seam" {
	run bash "$ENGINE"
	[ "$status" -eq 0 ]
	echo "$output" | grep -q 'sysctl forwarding verified'
	[ -f "$LIVE/etc/sysctl.d/90-host-hygiene-forwarding.conf" ]
	[ "$(cat "$LIVE/proc/sys/net/ipv4/ip_forward")" = "1" ]
	[ "$(cat "$LIVE/proc/sys/net/ipv6/conf/all/forwarding")" = "1" ]
	cp "$LIVE/etc/sysctl.d/90-host-hygiene-forwarding.conf" "$BATS_TEST_TMPDIR/dropin.v1"
	# the canonical self-copy went under the fixture, never the real /opt
	[ -f "$LIVE/opt/host-hygiene.sh" ]
	# second run: same bytes, same exit, sysctl (re)applied — no drift, no
	# write outside the fixture
	run bash "$ENGINE"
	[ "$status" -eq 0 ]
	cmp "$BATS_TEST_TMPDIR/dropin.v1" "$LIVE/etc/sysctl.d/90-host-hygiene-forwarding.conf"
	[ "$(wc -l < "$LIVE/sysctl.invocations")" = "2" ]
}

@test "apply: fails loud when the effective value does not take" {
	# the sysctl stub applies a drop-in that the kernel "refuses" for ipv6
	cat > "$STUB/sysctl" <<'STUB'
#!/bin/bash
ROOT="${HYGIENE_PROC_ROOT:?}"
mkdir -p "$ROOT/proc/sys/net/ipv4" "$ROOT/proc/sys/net/ipv6/conf/all"
printf '1\n' > "$ROOT/proc/sys/net/ipv4/ip_forward"
printf '0\n' > "$ROOT/proc/sys/net/ipv6/conf/all/forwarding"
exit 0
STUB
	chmod +x "$STUB/sysctl"
	run bash "$ENGINE"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q 'sysctl forwarding assertion FAILED'
	echo "$output" | grep -q "net.ipv6.conf.all.forwarding='0'"
	echo "$output" | grep -q "expected both '1'"
}

@test "check: drop-in drift reported; sysctl/systemctl/sshd/apt never invoked" {
	# Pin the fail2ban refresh knob off so the compared surface is identical
	# on every runner (the refresh trio's gate depends on fail2ban-client
	# presence — same pin hygiene-check.bats' unreadable-surface test uses).
	# The fail2ban DROP-IN itself is registered unconditionally by --check,
	# so it stays in the compared surface either way.
	export HYGIENE_FAIL2BAN_REFRESH=false
	# seed the complete managed fixture tree from the engine's OWN render
	# functions (same approach as tests/hygiene-check.bats)
	for fn in render_journald_dropin render_apt_auto_upgrades render_apt_unattended \
	          render_host_hygiene_env render_disk_watch_script render_disk_watch_service \
	          render_disk_watch_timer sshd_limits_dropin fail2ban_ignoreip_dropin \
	          render_sysctl_forwarding; do
		eval "$(sed -n "/^${fn}() {/,/^}$/p" "$ENGINE")"
		[ "$(type -t "$fn")" = "function" ]
	done
	# The fail2ban section-6 vars the engine's own assignments hold: the
	# drop-in render interpolates $FAIL2BAN_CACHE into its header comment and
	# needs $FAIL2BAN_CIDRS to render at all, so mirror the engine's values
	# (exactly like tests/hygiene-check.bats).
	FAIL2BAN_CACHE=/var/lib/host-hygiene/fail2ban-cidrs.txt
	FAIL2BAN_CIDRS="140.82.112.0/20 209.99.190.0/24 2603:1020::/47"
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
		"etc/sysctl.d/90-host-hygiene-forwarding.conf|render_sysctl_forwarding"; do
		rel="${spec%%|*}"
		fn="${spec#*|}"
		mkdir -p "$LIVE/$(dirname "$rel")"
		"$fn" > "$LIVE/$rel"
	done
	# The fail2ban drop-in is registered unconditionally by --check and
	# renders ONLY from the resolved-list cache (check never fetches/writes),
	# so seed the cache too, exactly like tests/hygiene-check.bats does.
	mkdir -p "$LIVE/var/lib/host-hygiene"
	printf '%s\n' $FAIL2BAN_CIDRS > "$LIVE/var/lib/host-hygiene/fail2ban-cidrs.txt"
	# every host-touching binary becomes a trap: check must not invoke any
	for b in systemctl sshd apt-get sysctl; do
		cat > "$STUB/$b" <<EOF
#!/bin/bash
echo "invoked $b" >> "$BATS_TEST_TMPDIR/marker"
exit 99
EOF
		chmod +x "$STUB/$b"
	done
	run env PATH="$STUB:$PATH" bash "$ENGINE" --check
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "check: 10 artifacts compared"
	echo "$output" | grep -q 'ok       /etc/sysctl.d/90-host-hygiene-forwarding.conf'
	echo "$output" | grep -q 'ok       /etc/fail2ban/jail.d/10-lds-ignoreip.conf'
	[ ! -e "$BATS_TEST_TMPDIR/marker" ]
	# drift on the drop-in -> exit 1 with the path and first differing line
	printf 'net.ipv4.ip_forward=0\n' > "$LIVE/etc/sysctl.d/90-host-hygiene-forwarding.conf"
	run bash "$ENGINE" --check
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "DRIFT    /etc/sysctl.d/90-host-hygiene-forwarding.conf"
	echo "$output" | grep -q 'differs at line 1'
	echo "$output" | grep -q "check: 10 artifacts compared"
	[ ! -e "$BATS_TEST_TMPDIR/marker" ]
}
