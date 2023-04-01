terraform {
  required_providers {
    linode = {
      source = "linode/linode"
      version = "1.30.0"
    }

    http = {
      source = "hashicorp/http"
      version = "3.2.1"
    }
  }
}

data "http" "github_keys" {
  url = "https://github.com/kejadlen.keys"
}

resource "linode_instance" "lotus_land_story" {
    label = "lotus-land-story"
    image = "linode/debian11"
    region = "us-west"
    type = "g6-nanode-1"
    authorized_keys = split("\n", chomp(data.http.github_keys.response_body))
}

output "lotus_land_story_ip" {
  value = resource.linode_instance.lotus_land_story.ip_address
}
