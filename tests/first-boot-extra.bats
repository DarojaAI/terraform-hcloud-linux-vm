#!/usr/bin/env bats
# tests/first-boot-extra.bats — the caller's first-boot script hook.

setup() {
	MODULE="$BATS_TEST_DIRNAME/.."
}

@test "main.tf passes the caller script and its presence flag to first-boot" {
	grep -q 'first_boot_extra_script          = var.first_boot_extra_script' "$MODULE/main.tf"
	grep -q 'first_boot_extra_script_present  = var.first_boot_extra_script != ""' "$MODULE/main.tf"
}

@test "first-boot runs the caller script only when one was supplied, after hygiene" {
	f="$MODULE/scripts/first-boot.sh"
	grep -q 'if \[ -n "${first_boot_extra_script_present}" \]; then' "$f"
	# quoted heredoc: the caller's script must not be shell-expanded on the way in
	grep -q "<<'FIRST_BOOT_EXTRA_EMBEDDED_EOF'" "$f"
	hygiene_line=$(grep -n 'bash "$HYGIENE_ENGINE"' "$f" | cut -d: -f1)
	extra_line=$(grep -n 'bash "$EXTRA"' "$f" | cut -d: -f1)
	[ "$hygiene_line" -lt "$extra_line" ]
}
