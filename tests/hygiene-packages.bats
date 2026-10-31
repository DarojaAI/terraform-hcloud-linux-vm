#!/usr/bin/env bats
# tests/hygiene-packages.bats — the HYGIENE_PACKAGES knob (workload runtime).
#
# L1 stays workload-agnostic: the engine installs whatever the list names and
# installs nothing when it is empty. The concrete consumer is
# linux-desktop-seed, which needs `podman` on the VM itself (its Route C
# contract reads image identity with `podman image inspect`).

setup() {
	ENGINE="$BATS_TEST_DIRNAME/../scripts/host-hygiene.sh"
	ROOT="$BATS_TEST_TMPDIR/root"
	mkdir -p "$ROOT"
}

run_dry() {
	HYGIENE_ROOT="$ROOT" HYGIENE_DRY_RUN=1 \
		HYGIENE_UNATTENDED_UPGRADES=false HYGIENE_DISK_ALERT_PCT=0 \
		HYGIENE_FAIL2BAN_IGNOREIP='' HYGIENE_FAIL2BAN_REFRESH=false \
		HYGIENE_SSHD_MAX_STARTUPS='' HYGIENE_SSHD_PERSOURCE_PENALTIES='' \
		HYGIENE_SYSCTL_FORWARDING=false \
		bash "$ENGINE"
}

@test "hygiene packages: a listed package is asserted in dry-run" {
	HYGIENE_PACKAGES="host-hygiene-test-pkg" run run_dry
	[ "$status" -eq 0 ]
	[[ "$output" == *"workload packages: 'host-hygiene-test-pkg'"* ]]
	[[ "$output" == *"would install package host-hygiene-test-pkg"* ]]
}

@test "hygiene packages: an empty list installs nothing" {
	run run_dry
	[ "$status" -eq 0 ]
	[[ "$output" == *"workload packages: '<none>'"* ]]
	[[ "$output" != *"host-hygiene-test-pkg"* ]]
}
