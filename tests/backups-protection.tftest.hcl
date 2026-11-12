# Plans the module against a mocked provider: no token, no API call, nothing
# created. Run with `terraform init -backend=false && terraform test`.

mock_provider "hcloud" {}

variables {
  hcloud_token = "mock-token"
  server_name  = "test-server"
}

run "defaults_leave_backups_and_protection_off" {
  command = plan

  assert {
    condition     = hcloud_server.main.backups == false
    error_message = "backups must be off by default: they cost money"
  }

  assert {
    condition     = hcloud_server.main.delete_protection == false && hcloud_server.main.rebuild_protection == false
    error_message = "protection must be off by default"
  }
}

run "enable_backups_sets_only_backups" {
  command = plan

  variables {
    enable_backups = true
  }

  assert {
    condition     = hcloud_server.main.backups == true
    error_message = "enable_backups must turn on server backups"
  }

  assert {
    condition     = hcloud_server.main.delete_protection == false && hcloud_server.main.rebuild_protection == false
    error_message = "enable_backups must not turn on protection"
  }
}

run "enable_protection_sets_delete_and_rebuild_together" {
  command = plan

  variables {
    enable_protection = true
  }

  assert {
    condition     = hcloud_server.main.delete_protection == true && hcloud_server.main.rebuild_protection == true
    error_message = "enable_protection must set delete and rebuild protection together"
  }

  assert {
    condition     = hcloud_server.main.backups == false
    error_message = "enable_protection must not turn on backups"
  }
}
