# imperishable-night

A shared Linode 8 GB running NixOS, replacing lotus-land-story. The root
tofu configuration creates it from a stock Debian image, and
nixos-anywhere replaces Debian with this flake. Run the commands below
from the repository root's `nix develop` shell.

## Prerequisites

The host joins the tailnet tagged `tag:server`. In the Tailscale admin
console, set up the following once:

- The policy file has
  `"tagOwners": {"tag:server": ["autogroup:admin"]}`.
- The `boxen-tailscale` OAuth client has write access on the `auth_keys`
  scope and `tag:server` among its tags.

Before installing on a new instance, set the following in its
configuration profile in Cloud Manager:

- Leave the kernel set to "GRUB 2".
- Turn off every Filesystem/Boot Helper.

## Install

The installed system accepts SSH only over the tailnet, so it joins on
first boot with a single-use auth key that the root tofu configuration
mints. The key expires a day after it's minted.

1. If an `imperishable-night` machine already exists in the tailnet,
   delete it in the admin console. Otherwise the new node registers as
   `imperishable-night-1`.
2. Mint the key. `tofu apply` mints it on first use. For a reinstall or
   an expired key, mint a new one:

   ```sh
   tofu apply -replace=tailscale_tailnet_key.imperishable_night
   ```

3. Stage the key where nixos-anywhere copies it onto the new system:

   ```sh
   extra=$(mktemp -d)
   install -d -m 755 "$extra/var/lib"
   (umask 077; tofu output -raw imperishable_night_auth_key \
     > "$extra/var/lib/tailscale-auth-key")
   ```

4. Install, with the instance's public IP. This wipes `/dev/sda`. Use
   `root@<ip>` for a fresh Debian instance. NixOS disables root login,
   so for a reinstall over NixOS, use `<ip>` instead. That only works
   while public SSH is still open.

   ```sh
   nixos-anywhere --flake './imperishable-night#imperishable-night' \
     --build-on remote --target-host root@<ip> --extra-files "$extra"
   rm -r "$extra"
   ```

5. Once `imperishable-night` shows up in the tailnet, drop the old host
   keys and delete the auth key from the host:

   ```sh
   ssh-keygen -R <ip>
   ssh-keygen -R imperishable-night
   ssh imperishable-night sudo rm /var/lib/tailscale-auth-key
   ```

   `ssh <ip>` now times out, since SSH is tailnet-only.

For later deploys, see the [root README](../README.md).

## Update nixpkgs

The personal dashboard's update tiles count the commits that the
`nixos-26.05` branch has gained since the deployed revision. The branch
takes dozens of backports a day, so a host a few days behind shows
hundreds of commits, not hundreds of package upgrades.

To catch up, run the following from the repository root:

1. Bump the nixpkgs input:

   ```sh
   nix flake update nixpkgs --flake ./imperishable-night
   ```

2. Commit `imperishable-night/flake.lock`.
3. Deploy with `just imperishable-night`.
4. If the security updates tile asks for a reboot, which happens when
   the bump changes the kernel or initrd, reboot the host:

   ```sh
   ssh imperishable-night sudo reboot
   ```

The tiles refresh within the hour, when the `update-metrics` timer next
runs. If you plan to reboot anyway, deploy with
`just imperishable-night boot` instead, so the new system activates
once, at boot.

## Rex

The
[Rex login server](https://www.superlogical.com/rex/docs/linux/login-server)
runs a Rex server as `alpha` for the Tailscale login in
`rex/tailscale_login` in `secrets.sops.yml`. Tailscale Serve exposes it
on port 7297, since Caddy holds 443. In Rex for Mac, choose
**Add Remote Host…** and enter
`https://imperishable-night.<tailnet>.ts.net:7297`.
