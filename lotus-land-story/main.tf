terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "1.30.0"
    }

    http = {
      source  = "hashicorp/http"
      version = "3.2.1"
    }
  }
}

variable "domain" {
  type     = string
  nullable = false
}

data "http" "github_keys" {
  url = "https://github.com/kejadlen.keys"
}

resource "linode_instance" "lotus_land_story" {
  label           = "lotus-land-story"
  image           = "linode/debian11"
  region          = "us-west"
  type            = "g6-nanode-1"
  authorized_keys = split("\n", chomp(data.http.github_keys.response_body))
}

resource "linode_volume" "lotus_land_story" {
  label     = "lotus-land-story"
  region    = "us-west"
  linode_id = linode_instance.lotus_land_story.id
  size      = 10

  connection {
    host = resource.linode_instance.lotus_land_story.ip_address
  }

  provisioner "remote-exec" {
    inline = [
      "mkfs.ext4 '${self.filesystem_path}'",
      "mkdir '/mnt/lotus-land-story'",
      "mount '${self.filesystem_path}' '/mnt/lotus-land-story'",
    ]
  }
}

data "linode_domain" "domain" {
  domain = var.domain
}

resource "linode_domain_record" "subdomains" {
  domain_id   = data.linode_domain.domain.id
  record_type = "A"
  target      = resource.linode_instance.lotus_land_story.ip_address

  for_each = toset(["rss", "prometheus", "grafana"])
  name = each.key
}

resource "linode_domain_record" "prometheus" {
  domain_id   = data.linode_domain.domain.id
  name        = "prometheus"
  record_type = "A"
  target      = resource.linode_instance.lotus_land_story.ip_address
}

output "lotus_land_story_ip" {
  value = resource.linode_instance.lotus_land_story.ip_address
}

output "lotus_land_story_volume" {
  value = resource.linode_volume.lotus_land_story.filesystem_path
}
