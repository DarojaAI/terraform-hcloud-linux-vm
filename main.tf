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

  # First-boot provisioning: pinned git (issue #2323) + generic host hygiene.
  # scripts/first-boot.sh is a templatefile that embeds scripts/git-pin.sh and
  # scripts/host-hygiene.sh as substitution values (they stay the single
  # source of truth for their engines) and exports this module's hygiene
  # variables as HYGIENE_* env vars for the engine. Both engines are
  # idempotent, and user_data is not ForceNew, so changing hygiene knobs or
  # re-applying never destroys existing servers. Existing VMs can be brought
  # up to date with `sudo bash scripts/bootstrap-hygiene.sh --apply` (README).
  user_data = templatefile("${path.module}/scripts/first-boot.sh", {
    git_pin_script              = file("${path.module}/scripts/git-pin.sh")
    hygiene_script              = file("${path.module}/scripts/host-hygiene.sh")
    hygiene_journald_max_use    = var.journald_max_use
    hygiene_docker_prune        = tostring(var.enable_docker_prune)
    hygiene_docker_prune_until  = var.docker_prune_until
    hygiene_unattended_upgrades = tostring(var.enable_unattended_upgrades)
    hygiene_disk_alert_pct      = tostring(var.disk_alert_pct)
    hygiene_disk_webhook_url    = var.disk_alert_webhook_url
  })

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