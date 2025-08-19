terraform {
  cloud {
    organization = "kejadlen"
    workspaces {
      name = "boxen"
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

provider "dnsimple" {
  token = "${var.dnsimple.token}"
  account = "${var.dnsimple.account}"
}

provider "linode" {
  # token = LINODE_TOKEN
}

provider "pihole" {
  url = "http://mountain-of-faith:80"
  password = var.pihole.password
}

provider "tailscale" {
  tailnet = "-"
  # oauth_client_id = TAILSCALE_OAUTH_CLIENT_ID
  # oauth_client_secret = TAILSCALE_OAUTH_CLIENT_SECRET
}

variable "dnsimple" {
  type = object({
    token   = string
    account = string
  })
  nullable = false
}

variable "pihole" {
  type = object({
    password   = string
  })
  nullable = false
}

variable "soa_email" {
  type     = string
  nullable = false
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

data "tailscale_device" "on_fire_within" {
  hostname = "on-fire-within"
}

locals {
  ramble_hard      = data.linode_instances.ramble_hard.instances.0
  lotus_land_story = data.linode_instances.lotus_land_story.instances.0
}

resource "linode_domain" "kejadlen_dev" {
  type      = "master"
  domain    = "kejadlen.dev"
  soa_email = var.soa_email
}

resource "linode_domain" "chislan_family" {
  type      = "master"
  domain    = "chislan.family"
  soa_email = var.soa_email
}

resource "pihole_dns_record" "domains" {
  for_each = {
    "birdnetpi" = data.tailscale_device.mountain_of_faith.addresses.0
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
