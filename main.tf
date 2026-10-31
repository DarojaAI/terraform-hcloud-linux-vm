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
  # idempotent. `user_data` IS ForceNew in the hcloud provider (cloud-init
  # only runs at first boot), so it is in `ignore_changes` below: changing a
  # hygiene knob must never recreate a live server. Existing VMs are brought
  # up to date with `sudo bash scripts/bootstrap-hygiene.sh --apply` (README).
  user_data = templatefile("${path.module}/scripts/first-boot.sh", {
    git_pin_script                   = file("${path.module}/scripts/git-pin.sh")
    hygiene_script                   = file("${path.module}/scripts/host-hygiene.sh")
    hygiene_journald_max_use         = var.journald_max_use
    hygiene_docker_prune             = tostring(var.enable_docker_prune)
    hygiene_docker_prune_until       = var.docker_prune_until
    hygiene_unattended_upgrades      = tostring(var.enable_unattended_upgrades)
    hygiene_disk_alert_pct           = tostring(var.disk_alert_pct)
    hygiene_disk_webhook_url         = var.disk_alert_webhook_url
    hygiene_sshd_max_startups        = var.sshd_max_startups
    hygiene_sshd_max_sessions        = tostring(var.sshd_max_sessions)
    hygiene_sshd_keepalive_interval  = tostring(var.sshd_keepalive_interval)
    hygiene_sshd_keepalive_count     = tostring(var.sshd_keepalive_count)
    hygiene_sshd_persource_penalties = var.sshd_persource_penalties
    hygiene_fail2ban_ignoreip        = var.fail2ban_ignoreip
    hygiene_fail2ban_refresh         = tostring(var.fail2ban_refresh)
    fail2ban_cidrs_file              = file("${path.module}/etc/fail2ban/github-actions-cidrs.txt")
    hygiene_sysctl_forwarding        = tostring(var.sysctl_forwarding)
  })

  labels = var.labels

  lifecycle {
    prevent_destroy = true

    # Creation-time-only attributes. Servers that were OS-upgraded in place
    # (do-release-upgrade 22.04 -> 24.04 -> 26.04) keep their original image
    # slug in the Hetzner API and in state; without this ignore_changes every
    # plan would show an image "change" (= destroy/recreate) and
    # prevent_destroy would refuse the deploy.
    #
    # `user_data` is ForceNew too: cloud-init runs once, at build time, so any
    # edit to the embedded engines (or to a hygiene knob) would otherwise plan
    # a whole-server replacement — every L1 hygiene change would be undeployable
    # and would trip prevent_destroy exactly like the 2026-10-31 L3 pin bump
    # did. A live host converges through `scripts/bootstrap-hygiene.sh
    # --apply`; a rebuilt host picks up the new user_data at creation.
    ignore_changes = [image, user_data]
  }
}
# =============================================================================
# Firewall (Lane C — test VM only, TCP 80/443 for caddy ACME HTTP-01 + exposure)
# =============================================================================
# Per DarojaAI/terraform-hcloud-linux-vm#7: Paperclip exposure on the test VM
# needs ACME HTTP-01 (port 80) + basicauth-fronted exposure (port 443). Source
# IPs are 0.0.0.0/0 + ::/0 — Let's Encrypt publishes no fixed validator IP
# list, and the exposure is basicauth-protected so a wide allowlist is the
# right tradeoff vs. cert renewal flakiness. Test VM only; head/prod are
# intentionally NOT exposed (paperclip ENABLE_PAPERCLIP gating + the
# pipeline-gating bats keep head/prod off this code path).
#
# Toggle: create_firewall (default true) so consumers can disable without
# editing HCL. The firewall itself is gated on var.firewall_target_env
# (test|head|prod) so accidentally setting create_firewall=true on a
# non-test consumer can never widen a head/prod surface.

variable "create_firewall" {
  description = "Create the hcloud_firewall and attach it to the server. Default true (Lane C test-VM exposure). Set false for consumers that manage firewall externally (e.g. via hcloud CLI)."
  type        = bool
  default     = true
}

variable "firewall_target_env" {
  description = "Which environment is this VM for? Must be 'test' to create the Lane C paperclip firewall (TCP 80+443 from 0.0.0.0/0 + ::/0). 'head' or 'prod' refuse — paperclip exposure is test-only. Issue DarojaAI/terraform-hcloud-linux-vm#7."
  type        = string
  default     = "test"

  validation {
    condition     = contains(["test", "head", "prod"], var.firewall_target_env)
    error_message = "firewall_target_env must be one of: test, head, prod."
  }
}

resource "hcloud_firewall" "paperclip_test_vm" {
  count = var.create_firewall && var.firewall_target_env == "test" ? 1 : 0
  name  = "${var.server_name}-paperclip-test-fw"

  # ACME HTTP-01 challenge path. Source: 0.0.0.0/0 + ::/0 (LE publishes no
  # fixed validator IP list).
  rule {
    direction       = "in"
    protocol        = "tcp"
    port            = "80"
    source_ips      = ["0.0.0.0/0", "::/0"]
    destination_ips = [hcloud_server.main.ipv4_address, hcloud_server.main.ipv6_address]
  }

  # Basicauth-fronted Paperclip exposure on :443. Source: 0.0.0.0/0 + ::/0
  # (caddy serves the basicauth prompt; an allowlist would deny browser
  # access from unknown IPs without warning).
  rule {
    direction       = "in"
    protocol        = "tcp"
    port            = "443"
    source_ips      = ["0.0.0.0/0", "::/0"]
    destination_ips = [hcloud_server.main.ipv4_address, hcloud_server.main.ipv6_address]
  }
}

resource "hcloud_firewall_attachment" "paperclip_test_vm" {
  count       = var.create_firewall && var.firewall_target_env == "test" ? 1 : 0
  firewall_id = hcloud_firewall.paperclip_test_vm[0].id
  server_ids  = [hcloud_server.main.id]
  depends_on  = [hcloud_firewall.paperclip_test_vm]
}
