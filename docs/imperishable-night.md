# imperishable-night

A shared Linode 8 GB (4 vCPU, 8 GB RAM, 160 GB disk) in `us-west`,
running NixOS from the flake in `imperishable-night/`. Services are moving
here from lotus-land-story one at a time; the
[migration plan](imperishable-night/2026-10-16-migrating-from-lotus-land-story.md)
tracks the order. Today it runs the base system, Tailscale,
node-exporter, cadvisor, restic, Caddy, Vector, homebox, ketchup,
paperless-ngx with redis, irc (soju, with gamja served by Caddy), and
quire.

For first-time setup, see the [bootstrap README][readme].

[readme]: ../imperishable-night/README.md

## Boot and disk

The layout follows Linode's
[NixOS guide](https://www.akamai.com/cloud/guides/install-nixos-on-linode/).
`/dev/sda` is ext4 with no partition table, and `/dev/sdb` is the 512 MB
swap disk that Linode creates with the instance. Those are the
configuration profile's slots. The kernel's own `sda` and `sdb` can come
up in the other order, so NixOS mounts both by their
`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi-disk-{0,1}` paths,
which follow the slots. The configuration
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
TCP 80 and 443 and UDP 443 for web traffic, TCP 22 for quire, and UDP
41641, so peers reach the host directly instead of through a relay.
sshd's `AllowUsers` admits only `quire` from the internet, and `alpha`
only from tailnet addresses. The `linode_firewall.imperishable_night`
Cloud Firewall in `main.tf` admits the same ports in front of the host,
in case podman's published ports skip the NixOS firewall. If Tailscale
breaks, the way back in is Linode's rescue mode, since `alpha` has no
password for Lish.

## Observability

node-exporter listens on `:9100`. VictoriaMetrics on lotus-land-story
scrapes it through the `linode` job in [scrape.yml][scrape], which
discovers every running Linode instance and scrapes `<label>:9100` over
the tailnet, so adding the host needed no scrape config change. The
firewall keeps the port closed publicly.

An hourly `update-metrics` timer, from `modules/nixos/update-metrics.nix`
and shared with every NixOS host, feeds node-exporter's textfile collector
for the personal dashboard's update tiles. It writes `node_reboot_required`
when the booted kernel, modules, or initrd differ from the current
system's, and asks GitHub how far the deployed nixpkgs revision trails the
`nixos-26.05` head, as `nixpkgs_branch_lag_seconds` and
`nixpkgs_branch_commits_behind`. When GitHub is unreachable, the branch
metrics keep their last values, and `node_textfile_mtime_seconds` shows
their age.

cadvisor runs from NixOS's `services.cadvisor` module rather than as a
container, so it needs no host mounts, and its version comes from nixpkgs
instead of lotus-land-story's pin. It listens on `:8080`, also closed
publicly, and finds containers through podman's socket. The `cadvisor` job
in the same scrape.yml lists `imperishable-night:8080` as a target. That
address is already the instance label, so only lotus-land-story's
in-network target needs relabeling.

Vector runs from NixOS's `services.vector` module and reads container
logs from journald, where podman writes them. It ships them to
VictoriaLogs on lotus-land-story at `https://logs`, verifying the
certificate against the shared Caddy root. Entries carry the same
`container_id` and `container_name` fields as lotus-land-story's, plus
`host` to tell the two hosts apart. Other journald entries stay on the
host; read them with `journalctl`.

[scrape]: ../lotus-land-story/templates/scrape.yml

## Containers and Caddy

Services run as podman containers through `virtualisation.oci-containers`.
Containers reach each other by name over podman networks, and each app
gets a network that it shares only with Caddy: `docs` for paperless-ngx,
`homebox`, `irc` for soju, `ketchup`, and `quire`. No app can reach
another app, so none can forge the login headers that paperless-ngx,
ketchup, and quire trust. paperless-ngx and redis also share
`paperless`, an internal network with no route out. Caddy alone is on
`caddy`, whose fixed subnet, `10.89.0.0/24`, the Caddyfile lists in
`trusted_proxies`. A oneshot unit creates each network, and each
container's unit requires the units for its networks. Container data
lives under `/var/lib/<service>`.

Caddy runs the same `ghcr.io/kejadlen/caddy-kejadlen` image as
lotus-land-story, with the [Caddyfile][caddyfile] mounted from the Nix
store, so changing it restarts the container on the next deploy. Each
tailnet site registers as its own Tailscale node, using a reusable
`tag:server` auth key that the root tofu configuration mints as
`tailscale_tailnet_key.imperishable_night_caddy`. The key expires after
90 days, Tailscale's maximum. It's only needed when a site registers, and
`tofu apply` mints a new one once it expires.

Tailnet sites use `tls internal`, and Caddy's local CA uses
lotus-land-story's root, so devices that already trust that root also
trust imperishable-night's sites. The root certificate is
`modules/nixos/caddy-root.crt`, and its key is a sops secret. Caddy
signs and renews its own intermediate from them.

## Secrets

sops-nix decrypts `imperishable-night/secrets.sops.yml` at activation,
with the age key derived from the host's SSH key, and renders Caddy's
and restic's environment files from it. [Backups](backup.md) covers
restic. The file holds the following values:

| Key | Source |
|---|---|
| `caddy.ts_authkey` | `tofu output -raw imperishable_night_caddy_auth_key` |
| `caddy.dnsimple_token` | `dnsimple.caddy_token` in `host_vars/lotus-land-story.sops.yml` |
| `caddy.ca_root_key` | `caddy/pki/authorities/local/root.key` in lotus-land-story's Caddy data directory |
| `docket.fastmail_tokens.<name>` | `docket.fastmail_tokens.<name>` in `host_vars/lotus-land-story.sops.yml`; unused until docket deploys |
| `docket.sentry_dsn` | `docket.sentry_dsn` in `host_vars/lotus-land-story.sops.yml`; unused until docket deploys |
| `homebox.api_key_pepper` | `openssl rand -base64 48`; rotating it invalidates homebox's API keys |
| `homebox.mailer.username` | `homebox.mailer.username` in `host_vars/lotus-land-story.sops.yml` |
| `homebox.mailer.password` | `homebox.mailer.password` in `host_vars/lotus-land-story.sops.yml` |
| `ketchup.session_secret` | `ketchup.session_secret` in `host_vars/lotus-land-story.sops.yml` |
| `ketchup.otel_exporter_otlp_headers` | `ketchup.otel_exporter_otlp_headers` in `host_vars/lotus-land-story.sops.yml` |
| `paperless_ngx.secret` | `paperless_ngx.secret` in `host_vars/lotus-land-story.sops.yml` |
| `quire.github_mirror` | `quire.github_mirror` in `host_vars/lotus-land-story.sops.yml` |
| `quire.github_auth_header` | `quire.github_auth_header` in `host_vars/lotus-land-story.sops.yml` |
| `quire.sentry_dsn` | `quire.sentry_dsn` in `host_vars/lotus-land-story.sops.yml` |
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

`alpha`'s packages come from the `profile` package in the dotfiles flake,
an input that `imperishable-night/flake.lock` pins. The dotfiles flake
locks its own nixpkgs, so every machine that uses it gets the same
versions. Tools that have DotSlash files in the dotfiles' `bin/` stay
out of the profile. To pick up a dotfiles change, push it, run
`nix flake update dotfiles --flake ./imperishable-night`, and deploy.
neovim comes from neovim-nightly-overlay, whose builds aren't in a
binary cache, so a deploy that bumps it builds neovim on the host.

When the personal dashboard shows the host behind nixpkgs, run
`nix flake update nixpkgs --flake ./imperishable-night`, commit the lock
file, and deploy. Inputs that follow nixpkgs build against the new
revision, but `alpha`'s packages don't change, since dotfiles locks its
own. The update tiles refresh within the hour, when the
`update-metrics` timer next runs. If the bump changes the kernel or
initrd, the security updates tile asks for a reboot; deploying with
`just imperishable-night boot` and then rebooting skips the extra
switch.

The `dotfiles-clone` service clones the dotfiles from GitHub into
`~alpha/.dotfiles` if they aren't already there. It never pulls, so
updating the checkout is up to `alpha`. To start over, remove the
directory and run `sudo systemctl start dotfiles-clone`.

The root tofu configuration ignores changes to the instance's image and
SSH keys, since either would recreate the instance and wipe NixOS.
