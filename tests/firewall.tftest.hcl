# Plan-only tests for the general firewall, against a mocked hcloud provider
# (no credentials, no API calls). Run with: terraform init && terraform test

mock_provider "hcloud" {
  # Hetzner IDs are numeric; the mock's random strings would not convert.
  mock_resource "hcloud_server" {
    defaults = { id = "1001" }
  }
  mock_resource "hcloud_firewall" {
    defaults = { id = "2001" }
  }
}

variables {
  hcloud_token        = "mock-token"
  server_name         = "test-vm"
  firewall_target_env = "prod" # keep the Paperclip firewall out of these tests
}

run "firewall_off_by_default" {
  command = plan

  assert {
    condition     = length(hcloud_firewall.general) == 0
    error_message = "the general firewall must stay opt-in in 1.x"
  }
}

run "firewall_on_limits_ssh_and_adds_extra_rules" {
  command = plan

  variables {
    enable_firewall = true
    ssh_source_ips  = ["10.0.0.0/8"]
    firewall_extra_rules = [
      { protocol = "tcp", port = "443", source_ips = ["0.0.0.0/0", "::/0"], description = "https" },
    ]
  }

  assert {
    condition     = length(hcloud_firewall.general) == 1 && length(hcloud_firewall_attachment.general) == 1
    error_message = "enable_firewall must create and attach the firewall"
  }

  assert {
    condition     = length(hcloud_firewall.general[0].rule) == 3
    error_message = "expected ssh, icmp and one extra rule"
  }

  assert {
    condition     = one([for r in hcloud_firewall.general[0].rule : r.source_ips if r.port == "22"]) == toset(["10.0.0.0/8"])
    error_message = "ssh must be limited to ssh_source_ips"
  }
}

run "firewall_on_without_ssh_ranges_fails" {
  command = plan

  variables {
    enable_firewall = true
  }

  expect_failures = [hcloud_firewall.general]
}

run "ssh_open_to_internet_is_refused" {
  command = plan

  variables {
    enable_firewall = true
    ssh_source_ips  = ["0.0.0.0/0"]
  }

  expect_failures = [var.ssh_source_ips]
}
