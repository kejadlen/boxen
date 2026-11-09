terraform {
  encryption {
    key_provider "external" "op" {
      command = ["./bin/tofu-state-key"]
    }

    method "aes_gcm" "op" {
      keys = key_provider.external.op
    }

    state {
      method   = method.aes_gcm.op
      enforced = true
    }

    plan {
      method   = method.aes_gcm.op
      enforced = true
    }
  }

  required_providers {
    dnsimple = {
      source  = "dnsimple/dnsimple"
      version = "~> 2.2"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }

    linode = {
      source  = "linode/linode"
      version = "~> 4.7"
    }

    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 3.3"
    }

    pihole = {
      source = "ryanwholey/pihole"

      # https://github.com/ryanwholey/terraform-provider-pihole/issues/86#issuecomment-2828469631
      version = "2.0.0-beta.1"
    }

    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29.2"
    }
  }
}

provider "onepassword" {
  account = "alydipha.1password.com"
}

# Items are looked up by UUID: lookups by title fail with SDK return code -4.
locals {
  op_private_vault = "7escx6csroqkgfrmkpdubfrqoa"
}

# boxen-dnsimple
ephemeral "onepassword_item" "dnsimple" {
  vault = local.op_private_vault
  uuid  = "urxqkxvbav5m2trwhzgwkg43pu"
}

# boxen-linode
ephemeral "onepassword_item" "linode" {
  vault = local.op_private_vault
  uuid  = "wgyjufgbnzfv6h6jvqy7g632ma"
}

# boxen-pihole
ephemeral "onepassword_item" "pihole" {
  vault = local.op_private_vault
  uuid  = "xpf55644ii3azfcl74tywiagb4"
}

# boxen-tailscale
ephemeral "onepassword_item" "tailscale" {
  vault = local.op_private_vault
  uuid  = "zoaigxq4d3kg3heqgobxlg4hdu"
}

provider "dnsimple" {
  token   = ephemeral.onepassword_item.dnsimple.credential
  account = ephemeral.onepassword_item.dnsimple.username
}

provider "linode" {
  token = ephemeral.onepassword_item.linode.credential
}

provider "pihole" {
  url      = "http://mountain-of-faith:80"
  password = ephemeral.onepassword_item.pihole.credential
}

provider "tailscale" {
  tailnet             = "-"
  oauth_client_id     = ephemeral.onepassword_item.tailscale.username
  oauth_client_secret = ephemeral.onepassword_item.tailscale.credential
}

data "linode_instances" "lotus_land_story" {
  filter {
    name   = "label"
    values = ["lotus-land-story"]
  }
}

data "tailscale_device" "lotus_land_story" {
  hostname = "lotus-land-story"
}

data "tailscale_device" "mountain_of_faith" {
  hostname = "mountain-of-faith"
}

# Caddy's tsnet node for pro-tacts.
data "tailscale_device" "contacts" {
  hostname = "contacts"
}

locals {
  lotus_land_story = data.linode_instances.lotus_land_story.instances.0
}

data "http" "github_keys" {
  url = "https://github.com/kejadlen.keys"
}

# Debian is only a launch pad: nixos-anywhere replaces it with NixOS.
resource "linode_instance" "imperishable_night" {
  label           = "imperishable-night"
  image           = "linode/debian13"
  region          = "us-west"
  type            = "g6-standard-4"
  authorized_keys = split("\n", chomp(data.http.github_keys.response_body))
  backups_enabled = true

  lifecycle {
    # Changing either would recreate the instance and wipe NixOS.
    ignore_changes = [authorized_keys, image]
  }
}

# Single-use, so it's spent after the install; mint another with -replace.
resource "tailscale_tailnet_key" "imperishable_night" {
  description   = "imperishable-night bootstrap"
  preauthorized = true
  expiry        = 86400
  tags          = ["tag:server"]
}

output "imperishable_night_auth_key" {
  value     = tailscale_tailnet_key.imperishable_night.key
  sensitive = true
}

# Reusable so caddy-tailscale can register a node per site. Copy it into
# imperishable-night/secrets.sops.yml whenever it's re-minted.
resource "tailscale_tailnet_key" "imperishable_night_caddy" {
  description         = "imperishable-night caddy"
  reusable            = true
  preauthorized       = true
  expiry              = 7776000 # 90 days, Tailscale's maximum.
  recreate_if_invalid = "always"
  tags                = ["tag:server"]
}

output "imperishable_night_caddy_auth_key" {
  value     = tailscale_tailnet_key.imperishable_night_caddy.key
  sensitive = true
}

import {
  to = tailscale_acl.policy
  id = "acl"
}

resource "tailscale_acl" "policy" {
  acl = <<-EOT
    {
      "tagOwners": {
        "tag:server":  ["autogroup:admin"],
        "tag:birdnet": ["autogroup:admin"],
      },

      "hosts": {
        "lotus-land-story":  "${data.tailscale_device.lotus_land_story.addresses[0]}",
        "mountain-of-faith": "${data.tailscale_device.mountain_of_faith.addresses[0]}",
      },

      "acls": [
        {
          "action": "accept",
          "src":    ["autogroup:member", "tag:server"],
          "dst":    ["*:*"],
        },
        // hopeless-masquerade runs BirdNET-Pi's third-party installer, so it
        // reaches only where it ships logs and resolves DNS.
        {
          "action": "accept",
          "src":    ["tag:birdnet"],
          "dst":    ["lotus-land-story:9428", "mountain-of-faith:53"],
        },
      ],

      "ssh": [
        {
          "action": "check",
          "src":    ["autogroup:member"],
          "dst":    ["autogroup:self"],
          "users":  ["autogroup:nonroot", "root"],
        },
      ],

      "tests": [
        {
          "src":    "tag:birdnet",
          "accept": ["lotus-land-story:9428", "mountain-of-faith:53"],
          "deny":   ["lotus-land-story:22", "mountain-of-faith:22", "mountain-of-faith:9000"],
        },
        {
          "src":    "tag:server",
          "accept": ["mountain-of-faith:22"],
        },
      ],
    }
  EOT
}

# doesn't seem to work
# resource "pihole_dns_record" "pi_hole" {
#   for_each = toset(["pi.hole"])
#
#   domain = each.key
#   ip     = data.tailscale_device.mountain_of_faith.addresses.0
# }
