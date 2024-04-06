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
      version = "2.18.0"
    }
  }
}

variable "soa_email" {
  type = string
  nullable = false
}

data "linode_instances" "ramble_hard" {
  filter {
    name = "label"
    values = ["ramble-hard"]
  }
}

data "linode_instances" "lotus_land_story" {
  filter {
    name = "label"
    values = ["lotus-land-story"]
  }
}

locals {
  ramble_hard = data.linode_instances.ramble_hard.instances.0
  lotus_land_story = data.linode_instances.lotus_land_story.instances.0
}

resource "linode_domain" "kejadlen_dev" {
  type = "master"
  domain = "kejadlen.dev"
  soa_email = var.soa_email
}

resource "linode_domain" "chislan_family" {
  type = "master"
  domain = "chislan.family"
  soa_email = var.soa_email
}
