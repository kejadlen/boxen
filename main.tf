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
      version = "~> 1.10"
    }

    linode = {
      source  = "linode/linode"
      version = "~> 2.18"
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
      version = "~> 0.17.2"
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

data "linode_instances" "ramble_hard" {
  filter {
    name   = "label"
    values = ["ramble-hard"]
  }
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
  ramble_hard      = data.linode_instances.ramble_hard.instances.0
  lotus_land_story = data.linode_instances.lotus_land_story.instances.0
}

resource "pihole_dns_record" "domains" {
  for_each = {
    "git.kejadlen.dev" = data.tailscale_device.lotus_land_story.addresses.0
  }

  domain = each.key
  ip     = each.value
}

# doesn't seem to work
# resource "pihole_dns_record" "pi_hole" {
#   for_each = toset(["pi.hole"])
#
#   domain = each.key
#   ip     = data.tailscale_device.mountain_of_faith.addresses.0
# }
