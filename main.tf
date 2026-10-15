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

  # First-boot provisioning of the pinned git (issue #2323). It ships
  # scripts/git-pin.sh to cloud-init so /opt/git-2.56.0 is built from the
  # kernel.org tarball and survives image rebuilds. Idempotent, and skips
  # only when /opt/git-2.56.0/bin/git is a real ELF binary (a clobbered
  # guard script at that path triggers a rebuild/repair). user_data is not
  # ForceNew, so updating it never destroys existing servers.
  user_data = file("${path.module}/scripts/git-pin.sh")

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