#!/usr/bin/env bats
# tests/terraform-no-replace.bats — pins the server's no-replace contract.
#
# 2026-10-31: the L3 pin bump to the hygiene-chain L1 tip (2e8330c) planned a
# whole-server replacement and `prevent_destroy` refused it:
#
#   Error: Instance cannot be destroyed
#     on .terraform/modules/vm/main.tf line 14, in resource "hcloud_server" "main"
#     Resource module.vm.hcloud_server.main has lifecycle.prevent_destroy set,
#     but the plan calls for this resource to be destroyed.
#
# Cause: `user_data` IS ForceNew in the hcloud provider (cloud-init runs once,
# at build time), so every engine or hygiene-knob edit — i.e. every L1 hygiene
# change — planned a destroy/recreate of the live VM. `ignore_changes` listed
# only `image`.
#
# This test pins both halves of the contract: the server can never be destroyed
# by a plan, and both creation-time-only attributes are ignored. It reads the
# module source because the only alternative is a credentialed plan against a
# live account, which is exactly what CI cannot do.

setup() {
	MODULE="$BATS_TEST_DIRNAME/.."
	MAIN="$MODULE/main.tf"
	[ -f "$MAIN" ]
}

# The hcloud_server lifecycle block, from `lifecycle {` to its closing brace.
server_lifecycle() {
	awk '/^resource "hcloud_server" "main"/{inserver=1}
	     inserver && /^  lifecycle \{/{inlife=1}
	     inlife{print}
	     inlife && /^  \}$/{exit}' "$MAIN"
}

@test "hcloud_server.main has prevent_destroy" {
	run server_lifecycle
	[ "$status" -eq 0 ]
	echo "$output" | grep -q 'prevent_destroy = true'
}

@test "hcloud_server.main ignores both creation-time-only attributes" {
	run server_lifecycle
	[ "$status" -eq 0 ]

	# The ignore_changes list itself (comments are allowed to name the
	# attributes, so match the assignment, not the prose).
	ignore_line="$(printf '%s\n' "$output" | grep '^    ignore_changes = ')"
	[ -n "$ignore_line" ]

	echo "$ignore_line" | grep -q 'image'
	echo "$ignore_line" | grep -q 'user_data'
}

@test "the comment does not claim user_data is safe to change" {
	# The old comment asserted "user_data is not ForceNew", which is false and
	# is what made the pin bump look safe. Keep the corrected statement.
	run grep -n 'user_data is not ForceNew' "$MAIN"
	[ "$status" -ne 0 ]
	run grep -n 'user_data. IS ForceNew' "$MAIN"
	[ "$status" -eq 0 ]
}
