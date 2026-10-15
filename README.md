# terraform-hcloud-linux-desktop

Terraform module for provisioning a Linux desktop server on Hetzner Cloud.

**Status:** Production-ready. Tested with Hetzner Cloud, Terraform 1.x, hetznercloud/hcloud provider >= 1.47.

---

## Table of Contents

- [What Problem Does This Solve?](#what-problem-does-this-solve)
- [Disclaimer](#disclaimer)
- [Tested On](#tested-on)
- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Quick Start](#quick-start)
  - [Connecting After Provisioning](#connecting-after-provisioning)
- [Module Reference](#module-reference)
  - [Requirements](#requirements)
  - [Inputs](#inputs)
  - [Outputs](#outputs)
  - [Configuration](#configuration)
- [Security Considerations](#security-considerations)
- [Performance & Limitations](#performance--limitations)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)
- [Contributing & License](#contributing--license)

---

## What Problem Does This Solve?

Provision a Linux desktop server on Hetzner Cloud in a single `terraform apply` — no manual cloud console work. Designed to work with the [linux-desktop-seed](https://github.com/DarojaAI/linux-desktop-seed) deployment scripts which handle OS setup, RDP, and development tools after the VM is created.

**Typical workflow:**

```
terraform apply (this module) → creates VM with public IP
        ↓
linux-desktop-seed/deploy-desktop.sh → installs desktop environment
        ↓
Connect via RDP → full Linux desktop
```

---

## Disclaimer

**Use at your own risk.** This module provisions real infrastructure that costs money. Review variable values before applying.

- No guarantees of stability, security, or fitness for any particular purpose
- Always `terraform plan` before `terraform apply`
- The [MIT license](LICENSE) applies: this software is provided "as is", without warranty of any kind

---

## Tested On

Validated against:

| Component | Version |
|---|---|
| Terraform | 1.7+ |
| Provider | hetznercloud/hcloud >= 1.47 |
| Location | fsn1, nbg1, hel1 |
| Image | ubuntu-22.04, ubuntu-24.04 |
| Server types | cx22, cpx21, cpx41, cpx51, cax41 |

---

## Getting Started

### Prerequisites

Before you can use this module, you need:

1. **A Hetzner Cloud project** — create one at [console.hetzner.cloud](https://console.hetzner.cloud/)
2. **An API token** — generate one in the Hetzner console under Access → API Tokens
3. **An SSH key** — create one in Hetzner under Access → SSH Keys (or use an existing key name)
4. **Terraform >= 1.0** installed locally

### Quick Start

**Step 1 — Create the Terraform configuration**

Create a file called `main.tf` in your project directory:

```hcl
module "linux_desktop" {
  source  = "DarojaAI/linux-desktop/hcloud"
  version = "1.0.0"

  hcloud_token = "your_hetzner_api_token"
  server_name  = "my-desktop"
  location     = "fsn1"
  server_type  = "cpx41"
  image        = "ubuntu-22.04"

  hetzner_ssh_key_name = "my-ssh-key"

  labels = {
    project    = "linux-desktop"
    managed_by = "terraform"
  }
}

output "connection_info" {
  value     = module.linux_desktop.connection_info
  sensitive = true
}

output "ipv4_address" {
  value = module.linux_desktop.ipv4_address
}
```

**Step 2 — Initialize and apply**

```bash
terraform init
terraform plan
terraform apply
```

You'll be prompted to confirm. Type `yes` when ready.

**Step 3 — Verify the server**

After `terraform apply` completes, run:

```bash
terraform output connection_info
```

This gives you the SSH command to connect. Verify the server is up:

```bash
ssh -o StrictHostKeyChecking=no root@<ipv4_address>
```

**Step 4 — Install the desktop environment**

Once the VM is up, run the linux-desktop-seed deployment scripts:

```bash
ssh root@<ipv4_address>
git clone https://github.com/DarojaAI/linux-desktop-seed.git
cd linux-desktop-seed
sudo bash deploy-desktop.sh
```

This installs GNOME, xrdp, VS Code, Claude Code, and everything else. Takes 5–15 minutes.

### Connecting After Provisioning

After the VM is provisioned and desktop environment is installed, connect via RDP:

**From Windows:**
- Open **Remote Desktop Connection** (search in Start menu)
- Server: `<ipv4_address>` (port 3389 is used automatically)
- Username: `desktopuser`
- Password: your Ubuntu password

**From Android:**
- Install **Microsoft Remote Desktop** from the Google Play Store
- Add a new PC with your server IP
- GNOME is touch-friendly

---

## Module Reference

### Requirements

| Resource | Version |
|---|---|
| Terraform | >= 1.0 |
| hetznercloud/hcloud provider | >= 1.47 |

Provider is configured automatically by this module. You only need to pass `hcloud_token`.

### Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `hcloud_token` | Hetzner API token. Create one at [console.hetzner.cloud](https://console.hetzner.cloud/) under Access → API Tokens | `string` | — | Yes |
| `server_name` | Server name. Must be unique in your Hetzner project. Used as the hostname and visible in the Hetzner console | `string` | — | Yes |
| `server_type` | Hetzner server type. See [hetzner.com/cloud/pricing](https://www.hetzner.com/cloud/pricing) | `string` | `"cpx41"` | No |
| `location` | Datacenter location. Options: `fsn1`, `nbg1`, `hel1`, `ash` | `string` | `"fsn1"` | No |
| `image` | OS image name or ID. Use slug (e.g., `ubuntu-22.04`) or numeric ID | `string` | `"ubuntu-22.04"` | No |
| `ssh_keys` | List of SSH key names or IDs to attach. Leave empty if using `hetzner_ssh_key_name` | `list(string)` | `[]` | No |
| `hetzner_ssh_key_name` | Name of a single SSH key in Hetzner. Alternative to `ssh_keys` for simpler setups | `string` | `""` | No |
| `ssh_public_key` | SSH public key content to inject at boot for passwordless access | `string` | `""` | No |
| `labels` | Key-value pairs to apply as labels to the server. Useful for organization and cost tracking | `map(string)` | `{}` | No |

#### Server Type Reference

| Type | vCPUs | RAM | Storage | Max Price |
|---|---|---|---|---|
| `cx22` | 2 | 4 GB | 40 GB | ~$4.89/mo |
| `cx32` | 2 | 8 GB | 80 GB | ~$6.89/mo |
| `cpx31` | 3 | 6 GB | 80 GB | ~$8.89/mo |
| `cpx41` | 4 | 8 GB | 160 GB | ~$12.59/mo |
| `cpx51` | 8 | 16 GB | 240 GB | ~$21.49/mo |
| `cax41` | 4 | 16 GB | 80 GB | ~$18.89/mo |

*Prices are approximate. Check [hetzner.com/cloud/pricing](https://www.hetzner.com/cloud/pricing) for current rates.*

### Outputs

| Name | Description |
|---|---|
| `server_id` | Hetzner server ID (useful for import) |
| `server_name` | Server name as specified |
| `ipv4_address` | Public IPv4 address. Use this to connect via SSH or RDP |
| `ipv6_address` | Public IPv6 address |
| `connection_info` | Ready-to-use SSH command. Example: `ssh -o StrictHostKeyChecking=no root@123.456.78.90` |
| `server_status` | Current server status: `running`, `off`, `creating`, `deleting` |

### Configuration

#### Backend (state storage)

This module does **not** include a `backend` block. State management is the consumer's responsibility. Recommended setup:

```hcl
terraform {
  backend "s3" {
    endpoints = {
      s3 = "https://s3.fra1.cloudprovider.de"
    }
    bucket         = "your-terraform-state-bucket"
    key            = "linux-desktop/terraform.tfstate"
    region         = "fra1"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    force_path_style            = true
  }
}
```

This separates state from the module. State files contain sensitive data — use encryption and access controls.

---

## Security Considerations

### API Token
`hcloud_token` is marked as `sensitive = true` in Terraform state. Protect your state file:
- Use remote backend with encryption (S3, Terraform Cloud)
- Never commit `.tfstate` files to version control
- Rotate tokens periodically via Hetzner console

### SSH Access
- Prefer `hetzner_ssh_key_name` or `ssh_keys` over `ssh_public_key` where possible
- If using `ssh_public_key`, ensure the private key is stored securely

### Firewall
This module does not create firewall rules. After provisioning, ensure port 3389 is open for RDP if you plan to use the desktop. Example with `hcloud_firewall`:

```hcl
resource "hcloud_firewall" "desktop" {
  name = "desktop-fw"

  rule {
    direction = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "in"
    protocol   = "tcp"
    port       = "3389"
    source_ips  = ["0.0.0.0/0"]  # restrict to your IP in production
  }

  apply_to {
    type = "server"
    id   = module.linux_desktop.server_id
  }
}
```

---

## Git Pinning (issue #2323)

This module owns the **git pin**: it builds git `2.56.0` from the canonical
[kernel.org tarball](https://www.kernel.org/pub/software/scm/git/git-2.56.0.tar.gz)
into `/opt/git-2.56.0` and ships the pinned binary on PATH. Previously this
lived only in the retiring L2 repo (`linux-desktop-seed`) and its installer was
`/tmp`-ephemeral, so a `/tmp` clean or image refresh lost the ability to repair
the pin and a guard script once overwrote the compiled binary (breaking
`git --version`). That is all corrected here.

### How it ships & survives image rebuilds

- `scripts/git-pin.sh` is the single source of truth. It is wired in as
  `hcloud_server.user_data` (cloud-init), so **every VM this module creates
  provisions the pin on first boot** — a fresh image rebuild therefore
  re-provisions it automatically.
- The script **self-copies to `/opt/git-pin.sh`**, so an operator can always
  repair/rebuild the pin later with `sudo bash /opt/git-pin.sh` — it no longer
  lives only in ephemeral `/tmp`.
- Setting `user_data` is **not** `ForceNew`, so reconfiguring existing servers
  never destroys them.

### Guard / wrapper layout contract (never overwrite binaries)

- `/opt/git-2.56.0/bin/git` — the **real compiled ELF binary**. It must never
  be a guard or a script at this path. This is what was clobbered before.
- `/usr/local/bin/git` — a **wrapper script** that `exec`s the pinned binary.
  Any guard/shim logic belongs here, at its own path, preserving the binary.
- To guard git, place the guard logic **in the wrapper** (or another shim path)
  and have it `exec /opt/git-2.56.0/bin/git` — never write a guard over the
  binary itself.

### Clobber detection

The script is idempotent, but its short-circuit is **sanity-checked**: it skips
only when `/opt/git-2.56.0/bin/git` exists **and** is a real ELF binary. If a
guard script (or any text) was ever written over the binary path, the file is
not ELF, so the script **rebuilds/repairs** the pin instead of blindly skipping.

---

## Performance & Limitations

| Metric | Value |
|---|---|
| Provision time | 1–3 minutes (Hetzner usually fast, can take longer under load) |
| First-boot git build | +2–5 min on the first boot of a fresh VM (only when the pin is absent; idempotent afterwards) |
| Server status check | Immediate via `hcloud_server.main.status` output |
| Idle cost |取决于 server_type — see pricing table above |

**Known limitations:**

- **First boot builds git from source** — every new VM this module creates
  compiles git 2.56.0 (via cloud-init `user_data`) to provision the pin. It is
  idempotent and skipped when `/opt/git-2.56.0/bin/git` is already a real
  binary, but a fresh image incurs a one-time build.
- **In-place OS upgrades (same instance, `ignore_changes = [image]`) do not
  re-run `user_data`.** The pin survives because `/opt` is untouched; to
  re-assert after drift, run `sudo bash /opt/git-pin.sh`.
- **No firewall rules** — must be created separately
- **No multi-region** — this module creates a single server in one location
- **No high availability** — single VM, single AZ
- **No automatic backups** — configure via Hetzner backup schedule manually
- **State not managed** — consumer must configure backend to avoid state loss

---

## Troubleshooting

### Server stays in `creating` state
Wait 1–2 minutes. Hetzner provisioning can take time for custom images or under high load.

### `Error: Invalid SSH key`
Ensure the SSH key name in `hetzner_ssh_key_name` exactly matches a key in your Hetzner project. SSH keys are project-scoped, not account-scoped.

### `Error: Image not found`
Use the exact image slug from Hetzner's available images. Check [docs.hetzner.cloud](https://docs.hetzner.cloud/servers#available-images) for the current list.

### `terraform apply` fails with 401
Your `hcloud_token` is invalid or expired. Generate a new one at [console.hetzner.cloud](https://console.hetzner.cloud/) → Access → API Tokens.

### How to import an existing server
If you have a server already running and want to manage it with Terraform:

```bash
terraform import hcloud_server.main <SERVER_ID>
```

Then run `terraform plan` to verify the imported state matches your configuration.

---

## Documentation

| Guide | Who It's For | What It Covers |
|---|---|---|
| [linux-desktop-seed](https://github.com/DarojaAI/linux-desktop-seed) | Everyone | Full desktop setup scripts (RDP, GNOME, VS Code, etc.) |
| [Hetzner Cloud Docs](https://docs.hetzner.cloud/) | Operators | Hetzner API reference, server options, networking |
| [Terraform Registry](https://registry.terraform.io/providers/hetznercloud/hcloud/latest) | Developers | Hetzner provider documentation |

---

## Contributing & License

### Module Structure

```
terraform-hcloud-linux-desktop/
├── main.tf         ← hcloud_server resource (incl. git-pin user_data)
├── scripts/        ← provisioner scripts shipped to the VM
│   └── git-pin.sh  ← builds/pins git 2.56.0 at /opt/git-2.56.0 (issue #2323)
├── variables.tf    ← all configurable inputs
├── outputs.tf      ← server connection info
├── versions.tf     ← terraform and provider version constraints
├── README.md       ← this file
└── LICENSE         ← MIT
```

### Contributing

When updating this module:

- Run `terraform fmt` and `terraform validate` before committing
- Update inputs/outputs tables in this README if variables change
- Test against a real Hetzner project (use a throwaway project for testing)
- State is consumer-managed — do not include `backend` blocks in this module
- Idempotency: `terraform apply` should be safe to run multiple times

---

## License

MIT — see [LICENSE](LICENSE) for the full text.