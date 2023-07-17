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
      version = "1.29.4"
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

resource "linode_domain" "kejadlen-dev" {
  type = "master"
  domain = "kejadlen.dev"
  soa_email = var.soa_email
}
