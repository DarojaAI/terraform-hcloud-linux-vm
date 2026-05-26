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
	}
}