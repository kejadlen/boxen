# imperishable-night

A shared Linode 8 GB (4 vCPU, 8 GB RAM, 160 GB disk) in `us-west`,
running NixOS from the flake in `imperishable-night/`. Services are moving
here from lotus-land-story one at a time; the
[migration plan](imperishable-night/2026-10-16-migrating-from-lotus-land-story.md)
tracks the order. Today it runs only the base system.

For first-time setup, see the [bootstrap README][readme].

[readme]: ../imperishable-night/README.md

## Boot and disk

The layout follows Linode's
[NixOS guide](https://www.akamai.com/cloud/guides/install-nixos-on-linode/).
`/dev/sda` is ext4 with no partition table, and `/dev/sdb` is the 512 MB
swap disk that Linode creates with the instance. The configuration
profile's "GRUB 2" kernel option reads GRUB's configuration off
`/dev/sda`, so NixOS installs GRUB with `device = "nodev"` and never
writes a boot sector. Linode's Filesystem/Boot Helpers are off because
they don't work with NixOS.

Lish, Linode's out-of-band console, reaches the host over the first
serial port at 19200 baud, through both GRUB and the kernel console.

## Access and deploys

Root login is disabled. `alpha` logs in with the keys from
`github.com/kejadlen.keys`, has passwordless sudo, and is a trusted Nix
user, so nixos-rebuild can copy closures in. The workstation evaluates
the flake and the host builds it; the [root README](../README.md) has the
deploy command.

The root tofu configuration ignores changes to the instance's image and
SSH keys, since either would recreate the instance and wipe NixOS.
