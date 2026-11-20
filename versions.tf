terraform {
  required_version = ">= 1.2" # lifecycle preconditions (firewall.tf); tests need >= 1.7

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.47"
    }
  }
}