# imperishable-night

A shared Linode 8 GB (4 vCPU, 8 GB RAM, 160 GB disk) in `us-west`,
running NixOS from the flake in `imperishable-night/`. Services are moving
here from lotus-land-story one at a time; the
[migration plan](imperishable-night/2026-10-16-migrating-from-lotus-land-story.md)
tracks the order. Today it runs the base system, Tailscale,
node-exporter, cadvisor, restic, Caddy, and paperless-ngx with redis.

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

## Tailscale

The host joins the tailnet as `imperishable-night`, tagged
`tag:server`. A tagged node belongs to the tag rather than to a user, and
its node key doesn't expire. The tailnet keeps Tailscale's default
allow-all policy, so the tag doesn't change what the host can reach. The
policy only needs the tag in `tagOwners`. On first boot, NixOS's
`tailscaled-autoconnect` service logs in with a single-use auth key that
the root tofu configuration mints as `tailscale_tailnet_key`.
nixos-anywhere writes the key to `/var/lib/tailscale-auth-key`. The node's
state then persists in `/var/lib/tailscale`, and the service reads the
key only when the node needs a login, so the key never enters the
repository or the Nix store.

The firewall trusts `tailscale0` completely. Publicly, it opens only
TCP 80 and 443 and UDP 443 for web traffic, and UDP 41641, so peers reach
the host directly instead of through a relay. SSH is tailnet-only. If Tailscale
breaks, the way back in is Linode's rescue mode, since `alpha` has no
password for Lish.

## Observability

node-exporter listens on `:9100`. VictoriaMetrics on lotus-land-story
scrapes it through the `linode` job in [scrape.yml][scrape], which
discovers every running Linode instance and scrapes `<label>:9100` over
the tailnet, so adding the host needed no scrape config change. The
firewall keeps the port closed publicly.

cadvisor runs from NixOS's `services.cadvisor` module rather than as a
container, so it needs no host mounts, and its version comes from nixpkgs
instead of lotus-land-story's pin. It listens on `:8080`, also closed
publicly, and finds containers through podman's socket. The `cadvisor` job
in the same scrape.yml lists `imperishable-night:8080` as a target. That
address is already the instance label, so only lotus-land-story's
in-network target needs relabeling.

[scrape]: ../lotus-land-story/templates/scrape.yml

## Containers and Caddy

Services run as podman containers through `virtualisation.oci-containers`,
on a podman network named `caddy` so that Caddy and the services reach
each other by name. A oneshot unit creates the network with a fixed subnet,
`10.89.0.0/24`, which the Caddyfile lists in `trusted_proxies`. Container
data lives under `/var/lib/<service>`.

Caddy runs the same `ghcr.io/kejadlen/caddy-kejadlen` image as
lotus-land-story, with the [Caddyfile][caddyfile] mounted from the Nix
store, so changing it restarts the container on the next deploy. Each
tailnet site registers as its own Tailscale node, using a reusable
`tag:server` auth key that the root tofu configuration mints as
`tailscale_tailnet_key.imperishable_night_caddy`. The key expires after
90 days, Tailscale's maximum. It's only needed when a site registers, and
`tofu apply` mints a new one once it expires.

## Secrets

sops-nix decrypts `imperishable-night/secrets.sops.yml` at activation,
with the age key derived from the host's SSH key, and renders Caddy's
and restic's environment files from it. [Backups](backup.md) covers
restic. The file holds the following values:

| Key | Source |
|---|---|
| `caddy.ts_authkey` | `tofu output -raw imperishable_night_caddy_auth_key` |
| `caddy.dnsimple_token` | `dnsimple.caddy_token` in `host_vars/lotus-land-story.sops.yml` |
| `paperless_ngx.secret` | `paperless_ngx.secret` in `host_vars/lotus-land-story.sops.yml` |
| `restic.password` | `restic.password` in `host_vars/lotus-land-story.sops.yml` |
| `restic.healthcheck` | The UUID of imperishable-night's healthchecks.io backup check |

Edit it with `sops imperishable-night/secrets.sops.yml`. Nix only sees
files that git tracks, so commit a new or changed secrets file before
deploying.

[caddyfile]: ../imperishable-night/Caddyfile

## Access and deploys

Root login is disabled. `alpha` logs in with the keys from
`github.com/kejadlen.keys`, has passwordless sudo, and is a trusted Nix
user, so nixos-rebuild can copy closures in. The workstation evaluates
the flake and the host builds it; the [root README](../README.md) has the
deploy command.

The root tofu configuration ignores changes to the instance's image and
SSH keys, since either would recreate the instance and wipe NixOS.
