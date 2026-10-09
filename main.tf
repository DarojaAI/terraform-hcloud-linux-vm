# =============================================================================
# Terraform Module: hcloud-linux-desktop
# =============================================================================
# Provisions a Linux desktop server on Hetzner Cloud

provider "hcloud" {
  token = var.hcloud_token
}

# =============================================================================
# Server
# =============================================================================

resource "hcloud_server" "main" {
	name        = var.server_name
	server_type = var.server_type
	location    = var.location
	image       = var.image

	ssh_keys = var.hetzner_ssh_key_name != "" ? [var.hetzner_ssh_key_name] : var.ssh_keys

	labels = var.labels

	lifecycle {
		prevent_destroy = true

		# The image attribute is creation-time-only. Servers that were OS-
		# upgraded in place (do-release-upgrade 22.04 -> 24.04 -> 26.04) keep
		# their original image slug in the Hetzner API and in state; without
		# this ignore_changes every plan would show an image "change" (=
		# destroy/recreate) and prevent_destroy would refuse the deploy.
		ignore_changes = [image]
	}
}