# imperishable-night

A shared Linode 8 GB running NixOS, replacing lotus-land-story. The root
tofu configuration creates it from a stock Debian image, and
nixos-anywhere replaces Debian with this flake.

## Bootstrapping

Before installing, set the following in the instance's configuration
profile in Cloud Manager:

- Leave the kernel set to "GRUB 2".
- Turn off every Filesystem/Boot Helper.

Then install from the repository root's `nix develop` shell, with the
instance's public IP:

```sh
nixos-anywhere --flake './imperishable-night#imperishable-night' \
  --build-on remote --target-host root@<ip>
```

NixOS disables root login, so SSH in as `alpha` afterward. For later
deploys, see the [root README](../README.md).
