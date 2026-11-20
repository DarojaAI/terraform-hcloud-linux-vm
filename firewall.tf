# =============================================================================
# General-purpose firewall (opt-in in 1.x)
# =============================================================================
# Hetzner drops all inbound traffic that a firewall attached to the server does
# not allow, so this firewall is the server's whole inbound surface: SSH from
# the caller's IP ranges, optional ICMP, and any extra ports the caller lists.
# Outbound traffic is not restricted.
#
# Opt-in for now (enable_firewall defaults to false) so existing callers see no
# change when they bump. A future major release turns it on by default.
#
# It can be attached alongside other firewalls (including the Paperclip one in
# main.tf); Hetzner allows the union of their rules.

variable "enable_firewall" {
  description = "Create the general firewall and attach it to the server. When on, inbound traffic is limited to SSH from ssh_source_ips, ICMP (if allow_icmp), and firewall_extra_rules."
  type        = bool
  default     = false
}

variable "ssh_source_ips" {
  description = "CIDRs allowed to reach SSH (TCP 22) when enable_firewall is true. Required when the firewall is on. 0.0.0.0/0 and ::/0 are refused: to leave SSH open to the internet, leave the firewall off."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.ssh_source_ips : can(cidrhost(c, 0))])
    error_message = "ssh_source_ips must be CIDRs, e.g. 203.0.113.0/24 or 2001:db8::/32."
  }

  # Refuse any range that covers the whole IPv4 or IPv6 space, however it is
  # spelled (0.0.0.0/0, ::/0, 0::/0, ...). Splitting it into halves
  # (0.0.0.0/1 + 128.0.0.0/1) is not caught; the firewall is meant for real
  # allow-lists. (try(): Terraform's || does not short-circuit, and
  # malformed entries are reported by the CIDR check above.)
  validation {
    condition     = alltrue([for c in var.ssh_source_ips : try(tonumber(split("/", c)[1]) > 0, true)])
    error_message = "ssh_source_ips must not open SSH to the whole internet (a /0 range). Leave the firewall off for that."
  }
}

variable "allow_icmp" {
  description = "Allow inbound ICMP (ping) from anywhere when the firewall is on."
  type        = bool
  default     = true
}

variable "firewall_extra_rules" {
  description = "Extra inbound rules when the firewall is on, e.g. [{ protocol = \"tcp\", port = \"443\", source_ips = [\"0.0.0.0/0\", \"::/0\"], description = \"https\" }]. port may be a range (\"8000-8100\")."
  type = list(object({
    protocol    = string
    port        = string
    source_ips  = list(string)
    description = string
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.firewall_extra_rules : contains(["tcp", "udp"], r.protocol)])
    error_message = "firewall_extra_rules: protocol must be tcp or udp (ICMP is controlled by allow_icmp)."
  }
}

resource "hcloud_firewall" "general" {
  count  = var.enable_firewall ? 1 : 0
  name   = "${var.server_name}-fw"
  labels = var.labels

  rule {
    description = "ssh"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.ssh_source_ips
  }

  dynamic "rule" {
    for_each = var.allow_icmp ? [1] : []
    content {
      description = "icmp"
      direction   = "in"
      protocol    = "icmp"
      source_ips  = ["0.0.0.0/0", "::/0"]
    }
  }

  dynamic "rule" {
    for_each = var.firewall_extra_rules
    content {
      description = rule.value.description
      direction   = "in"
      protocol    = rule.value.protocol
      port        = rule.value.port
      source_ips  = rule.value.source_ips
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.ssh_source_ips) > 0
      error_message = "enable_firewall = true needs at least one CIDR in ssh_source_ips, or SSH would be unreachable."
    }
  }
}

resource "hcloud_firewall_attachment" "general" {
  count       = var.enable_firewall ? 1 : 0
  firewall_id = hcloud_firewall.general[0].id
  server_ids  = [hcloud_server.main.id]
}

output "general_firewall_id" {
  description = "ID of the general firewall (null when enable_firewall is false)."
  value       = try(hcloud_firewall.general[0].id, null)
}
