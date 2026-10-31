# =============================================================================
# Variables
# =============================================================================

variable "hcloud_token" {
  description = "Hetzner API token"
  type        = string
  sensitive   = true
}

variable "server_name" {
  description = "Name of the server (must be unique in your Hetzner project)"
  type        = string
}

variable "server_type" {
  description = "Hetzner server type (e.g., cpx21, cpx41, cax41)"
  type        = string
  default     = "cpx41"
}

variable "location" {
  description = "Hetzner datacenter location (e.g., fsn1, nbg1, hel1)"
  type        = string
  default     = "fsn1"
}

variable "image" {
  description = "OS image to use (slug or ID)"
  type        = string
  default     = "ubuntu-22.04"
}

variable "ssh_keys" {
  description = "List of SSH key names or IDs to attach"
  type        = list(string)
  default     = []
}

variable "hetzner_ssh_key_name" {
  description = "Name of a single SSH key in Hetzner (alternative to ssh_keys)"
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key content to inject at boot"
  type        = string
  default     = ""
}

variable "labels" {
  description = "Labels to apply to the server"
  type        = map(string)
  default = {
    managed_by = "terraform"
  }
}

# =============================================================================
# Host hygiene (generic, workload-agnostic bounds — L1 scope)
# =============================================================================

variable "journald_max_use" {
  description = "journald SystemMaxUse cap written to /etc/systemd/journald.conf.d/90-host-hygiene.conf (journald size syntax, e.g. 100M, 1G). Bounds the journal so it can never fill the root disk."
  type        = string
  default     = "1G"

  validation {
    condition     = can(regex("^[0-9]+[KMG]?$", var.journald_max_use))
    error_message = "journald_max_use must be a journald size such as \"500M\", \"1G\", or a plain byte count."
  }
}

variable "enable_docker_prune" {
  description = "Install and enable the weekly docker-prune systemd timer (prunes dangling images with `docker system prune -f --filter until=...`; never -a, never volumes). Ignored on VMs without docker."
  type        = bool
  default     = true
}

variable "docker_prune_until" {
  description = "Age filter for the docker-prune timer (`docker system prune --filter until=...`), e.g. 24h, 7d via h/m. Reclaimed only for images older than this."
  type        = string
  default     = "168h"

  validation {
    condition     = can(regex("^[0-9]+[smhd]$", var.docker_prune_until))
    error_message = "docker_prune_until must be a docker duration such as \"24h\" or \"168h\" (digits followed by s/m/h/d)."
  }
}

variable "enable_unattended_upgrades" {
  description = "Ensure unattended-upgrades is installed and configured for SECURITY-ONLY automatic upgrades ($${distro_id}:$${distro_codename}-security origins) with no automatic reboot."
  type        = bool
  default     = true
}

variable "disk_alert_pct" {
  description = "Root-filesystem used-percent threshold for the weekly generic disk-watch alarm (0 disables the alarm). When crossed it emits a loud journald warning marker and, if disk_alert_webhook_url is set, POSTs a JSON alert."
  type        = number
  default     = 85

  validation {
    condition     = var.disk_alert_pct >= 0 && var.disk_alert_pct <= 100
    error_message = "disk_alert_pct must be between 0 (alarm off) and 100."
  }
}

variable "disk_alert_webhook_url" {
  description = "Optional webhook URL for disk-watch alarms (JSON POST on alarm). Empty string disables webhook delivery; the journald marker is always emitted."
  type        = string
  default     = ""
}

variable "sshd_max_startups" {
  description = "MaxStartups value for the sshd drop-in /etc/ssh/sshd_config.d/09-sshd-limits.conf (start:rate:full, e.g. 40:30:100). Bounds unauthenticated concurrent connections so internet scanners cannot starve CI/SSH. The 09- prefix sorts before (and shadows, sshd keeps the first value) the retired L2 repo's 10-l2.conf (MaxStartups 3:50:10), which dropped 50% of connections at random from the 3rd scanner in — 54 'drop connection ... Maxstartups' events in 6 h and CI flakes with 'kex_exchange_identification: read: Connection reset by peer'. Set to \"0\" to stop managing sshd connection bounds via host hygiene."
  type        = string
  default     = "40:30:100"

  validation {
    condition     = can(regex("^(0|[0-9]+:[0-9]+:[0-9]+)$", var.sshd_max_startups))
    error_message = "sshd_max_startups must be a MaxStartups triple like \"40:30:100\", or \"0\" to stop managing sshd bounds."
  }
}

variable "sshd_persource_penalties" {
  description = "PerSourcePenalties keyword overrides for the same sshd drop-in 09-sshd-limits.conf (issue #11). OpenSSH 10.2 enables per-source penalties by default; the noauth:1 term makes a CI deploy's short-lived pre-auth SSH/scp connections from one runner IP accrue a penalty (up to max 600s) and get refused with the SAME 'kex_exchange_identification: read: Connection reset by peer' as a MaxStartups drop. The default \"noauth:0\" relaxes only that priming term — a partial override, so every other keyword (crash/authfail/grace-exceeded/refuseconnection/max/min) keeps the distro default. Set to \"\" to leave the distro policy untouched (no line rendered)."
  type        = string
  default     = "noauth:0"

  validation {
    condition     = can(regex("^$|^[a-z0-9-]+:[0-9]+[smhdw]?([[:space:]]+[a-z0-9-]+:[0-9]+[smhdw]?)*$", var.sshd_persource_penalties))
    error_message = "sshd_persource_penalties must be space-separated PerSourcePenalties keywords with durations in seconds or s/m/h/d/w (e.g. \"noauth:0\" or \"noauth:0 max:120\"), or \"\" to leave the distro default."
  }
}

variable "sshd_max_sessions" {
  description = "MaxSessions for the sshd drop-in 09-sshd-limits.conf (concurrent sessions per connection)."
  type        = number
  default     = 20
}

variable "sshd_keepalive_interval" {
  description = "ClientAliveInterval seconds for the sshd drop-in 09-sshd-limits.conf (server keepalive packets; drops dead connections)."
  type        = number
  default     = 60
}

variable "sshd_keepalive_count" {
  description = "ClientAliveCountMax for the sshd drop-in 09-sshd-limits.conf (unanswered keepalives before disconnect)."
  type        = number
  default     = 3
}

variable "fail2ban_ignoreip" {
  description = "Extra IP/CIDR ranges appended to the fail2ban sshd jail's ignoreip in /etc/fail2ban/jail.d/10-lds-ignoreip.conf (space-separated), on top of loopback and the GitHub Actions runner egress ranges. The GitHub ranges are resolved live from https://api.github.com/meta -> \"actions\" at install time and refreshed weekly by the fail2ban-ignoreip-refresh timer (GitHub updates them weekly); a dated static snapshot embedded in the engine covers network-fetch failures so the jail never loses its exemptions. Issue DarojaAI/terraform-hcloud-linux-vm#10: runner IPs were banned mid-deploy by the sshd jail (maxretry 5), burning the deploy's rc=255 retry budget. Empty string = no extra ranges."
  type        = string
  default     = ""

  validation {
    condition     = var.fail2ban_ignoreip == "" || alltrue([for cidr in compact(split(" ", var.fail2ban_ignoreip)) : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9a-fA-F:]+/[0-9]{1,3}$", cidr))])
    error_message = "fail2ban_ignoreip must be a space-separated list of IPv4/IPv6 CIDR ranges (e.g. \"203.0.113.0/24\"), or empty."
  }
}

variable "fail2ban_refresh" {
  description = "Install and enable the weekly fail2ban-ignoreip-refresh systemd timer: re-resolves the GitHub Actions runner ranges from api.github.com/meta and reloads fail2ban ONLY when the rendered ignoreip drop-in changed. false = still manage the ignoreip drop-in but skip the refresh unit."
  type        = bool
  default     = true
}

variable "sysctl_forwarding" {
  description = "Write /etc/sysctl.d/90-host-hygiene-forwarding.conf enabling IPv4 + IPv6 packet forwarding (net.ipv4.ip_forward=1, net.ipv6.conf.all.forwarding=1), apply it with `sysctl --system`, and assert the effective values from /proc/sys. Closes the writer gap for linux-desktop-seed verify-vm-state.sh check 6, which asserts exactly these two keys; until this drop-in existed the assert passed only because something outside both repos set them. Set false to stop managing forwarding via host hygiene."
  type        = bool
  default     = true
}
