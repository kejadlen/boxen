terraform {
  cloud {
    organization = "kejadlen"
    workspaces {
      name = "boxen"
    }
  }
}

variable "GOOGLE_CREDENTIALS" {}

provider "google" {
  project = "kejadlen"
  region  = "us-west1"
}

module "google_image_nixos" {
  source        = "github.com/tweag/terraform-nixos/google_image_nixos"
  nixos_version = "latest"
}

resource "google_compute_instance" "imperishable_night" {
  count = 0

  name         = "imperishable-night"
  machine_type = "e2-standard-2"
  zone         = "us-west1-a"

  boot_disk {
    initialize_params {
      image = module.google_image_nixos.self_link
    }
  }

  network_interface {
    network = "default"
  }
}
