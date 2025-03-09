terraform {
  cloud {
    organization = "kejadlen"
    workspaces {
      name = "boxen"
    }
  }

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.18"
    }

    pihole = {
      source  = "ryanwholey/pihole"
      version = "~> 0.2"
    }

    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17.2"
    }
  }
}

provider "linode" {
  # token = LINODE_TOKEN
}

provider "pihole" {
  url = "https://pihole.kejadlen.dev"
  # api_token = # PIHOLE_API_TOKEN
}

provider "tailscale" {
  tailnet = "-"
  # oauth_client_id = TAILSCALE_OAUTH_CLIENT_ID
  # oauth_client_secret = TAILSCALE_OAUTH_CLIENT_SECRET
}

variable "soa_email" {
  type     = string
  nullable = false
}

variable "subdomains" {
  type     = map(list(string))
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

resource "pihole_dns_record" "rss" {
  for_each = toset(["git.kejadlen.dev"])

  domain = each.key
  ip     = data.tailscale_device.lotus_land_story.addresses.0
}
