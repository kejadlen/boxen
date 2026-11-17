# imperishable-night

A shared Linode 8 GB (4 vCPU, 8 GB RAM, 160 GB disk) in `us-west`,
running NixOS from the flake in `imperishable-night/`. Every service
that outlives lotus-land-story has moved here, following the
[migration plan](imperishable-night/2026-10-16-migrating-from-lotus-land-story.md).
It runs the base system, Tailscale,
node-exporter, cadvisor, restic, PostgreSQL, Caddy, Vector, Grafana,
VictoriaMetrics, VictoriaLogs, VictoriaTraces, authelia, calibre-web,
gotosocial, homebox, ketchup, miniflux, paperless-ngx with redis, irc
(soju, with gamja served by Caddy), pro-tacts, quire, and the sites
that only Caddy serves.

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

Swap is encrypted with a random key that NixOS generates at each boot,
so memory paged out to `/dev/sdb`, secrets included, can't be read from
the disk afterward. Hibernation can't work with it, and nothing here
uses hibernation.

Lish, Linode's out-of-band console, reaches the host over the first
serial port at 19200 baud, through both GRUB and the kernel console.

## Tailscale

The host joins the tailnet as `imperishable-night`, tagged `tag:server`.
A tagged node belongs to the tag rather than to a user, and its node key
doesn't expire. The tailnet keeps Tailscale's default allow-all policy,
so the tag doesn't change what the host can reach. The policy only needs
the tag in `tagOwners`. On first boot, NixOS's `tailscaled-autoconnect`
service logs in with a single-use auth key that the root tofu
configuration mints as `tailscale_tailnet_key`. nixos-anywhere writes
the key to `/var/lib/tailscale-auth-key`. The node's state then persists
in `/var/lib/tailscale`, and the service reads the key only when the
node needs a login, so the key never enters the repository or the Nix
store.

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

The fleet's observability stack runs here as four containers, each with
its data in `/var/lib/<name>`:

- VictoriaMetrics, at `https://metrics`, scrapes the targets in
  [scrape.yml][scrape] and takes `backup_*` pushes from both hosts'
  backups and `deploy_*` pushes from the deploy recipes. It keeps a
  year of data, so deploy markers outlast the default month, at about
  1 GB a month.
- VictoriaLogs, at `https://logs`, takes logs from every host's Vector
  or journal-upload.
- VictoriaTraces, at `https://traces`, takes OpenTelemetry traces.
  pro-tacts and ketchup send their traces there over the tailnet,
  trusting the Caddy root, rather than sharing a network with
  VictoriaTraces.
- Grafana, at `https://grafana`, reads all three over `observability`.
  Caddy signs users in with `tailscale_auth` and passes the Tailscale
  user as `X-WEBAUTH-USER`, which Grafana's auth proxy takes as a login
  only from the `grafana` subnet. `auto_sign_up` is off, so only
  existing Grafana users get in. Its datasources and the dashboard
  provider come from the flake, and the dashboards from
  `imperishable-night/dashboards/`. The Uptime library panel lives only
  in Grafana's database; `imperishable-night/library-panels/` holds a
  copy that nothing deploys.

The `logs`, `metrics`, and `traces` sites skip `tailscale_auth`, since
the shippers and scrapers that use them run on tagged nodes, which it
rejects.

node-exporter listens on `:9100`. VictoriaMetrics scrapes it through the
`linode` job in [scrape.yml][scrape], which discovers every running
Linode instance and scrapes `<label>:9100` over the tailnet. The
firewall keeps the port closed publicly.

An hourly `update-metrics` timer, from
`modules/nixos/update-metrics.nix` and shared with every NixOS host,
feeds node-exporter's textfile collector for the personal dashboard's
update tiles. It writes `node_reboot_required` when the booted kernel,
modules, or initrd differ from the current system's, and asks GitHub how
far the deployed nixpkgs revision trails the `nixos-26.05` head, as
`nixpkgs_branch_lag_seconds` and `nixpkgs_branch_commits_behind`. When
GitHub is unreachable, the branch metrics keep their last values, and
`node_textfile_mtime_seconds` shows their age.

cadvisor runs from NixOS's `services.cadvisor` module rather than as a
container, so it needs no host mounts, and its version comes from
nixpkgs instead of lotus-land-story's pin. It listens on `:8080`, also
closed publicly, and finds containers through podman's socket. The
`cadvisor` job in the same scrape.yml scrapes `imperishable-night:8080`.
lotus-land-story's cadvisor publishes no port, so the
`cadvisor-lotus-land-story` job reaches it through lotus-land-story's
`https://cadvisor` site and relabels it to the `cadvisor` job and the
`lotus-land-story:8080` instance.

Vector runs from NixOS's `services.vector` module and reads container
logs from journald, where podman writes them. It ships them to
VictoriaLogs at `https://logs`, verifying the
certificate against the shared Caddy root. Entries carry the same
`container_id` and `container_name` fields as lotus-land-story's, plus
`host` to tell the two hosts apart. Other journald entries stay on the
host; read them with `journalctl`.

The `miniflux` job in the same scrape.yml reaches miniflux at
`https://rss/metrics` through Caddy. miniflux allows the request because
it arrives from Caddy's address on the `rss` network. The `rss` site
serves `/metrics` outside `tailscale_auth`, which rejects tagged nodes
such as imperishable-night itself, so any tailnet node can read the
metrics.

The `authelia` and `gotosocial` jobs reach authelia's `:9959` and
gotosocial's `:9464` at `https://authelia/metrics` and
`https://gotosocial/metrics`. Each is a tailnet site that serves only
that path and skips `tailscale_auth` for the same reason, so
VictoriaMetrics shares no network with either app. The public
`hey.kejadlen.dev` answers `/metrics` with a 404.

[scrape]: ../imperishable-night/scrape.yml

## Containers and Caddy

Services run as podman containers through
`virtualisation.oci-containers`. Containers reach each other by name
over podman networks, and each app gets a network that it shares only
with Caddy: `authelia`, `books` for calibre-web, `docs` for
paperless-ngx, `gotosocial`, `grafana`, `homebox`, `irc` for soju,
`ketchup`, `logs` for VictoriaLogs, `metrics` for VictoriaMetrics,
`pro-tacts`, `quire`, `rss` for miniflux, and `traces` for
VictoriaTraces. No app can reach another app, so none can forge the
login headers that paperless-ngx, ketchup, quire, miniflux, and Grafana
trust, and none can reach authelia except through Caddy. redis has no
network at all: paperless-ngx reaches it through a Unix socket in
`/run/paperless-redis`, which both containers mount. The two used to
share an internal network, but its resolver never answered a lookup it
couldn't satisfy, which added 5 seconds to nearly every paperless-ngx
request.
Grafana and the three Victorias share `observability`, which Caddy
isn't on. It isn't internal, because an internal network's resolver
never answers for outside names, and Go's resolver waits 5 seconds on
it before asking the next one, which timed out VictoriaMetrics'
scrapes. Caddy alone is on `caddy`, whose
fixed subnet, `10.89.0.0/24`, the Caddyfile lists in `trusted_proxies`.
`rss` also has a fixed subnet, `10.89.255.0/24`, which miniflux trusts
for its login header and its metrics endpoint, and `gotosocial` has
`10.89.254.0/24`, which gotosocial trusts for `X-Forwarded-For`, and
`grafana` has `10.89.253.0/24`, which Grafana's auth proxy whitelists.
`metrics`' bridge is named `podman-metrics`, and the firewall opens
cadvisor's and node-exporter's ports on it, since VictoriaMetrics'
scrapes of the host's tailnet name arrive there instead of on
`tailscale0`. VictoriaMetrics' `/etc/hosts` starts empty, because
podman otherwise copies the host's, which maps `imperishable-night` to
`127.0.0.2`. Netavark publishes Caddy's ports on every network it
joins and DNATs them to whichever network's rule comes first, while the
reply leaves by
whichever default route Caddy picks. The host's reverse-path filter is
loose so those replies aren't dropped. A oneshot unit creates each
network, and each container's unit requires the units for its networks.
The unit skips a network that already exists, so changing a network's
options means removing it by hand first. Container data lives under
`/var/lib/<service>`.

Caddy runs the same `ghcr.io/kejadlen/caddy-kejadlen` image as
lotus-land-story, with the [Caddyfile][caddyfile] mounted from the Nix
store, so changing it restarts the container on the next deploy. Each
tailnet site registers as its own Tailscale node, using a reusable
`tag:server` auth key that the root tofu configuration mints as
`tailscale_tailnet_key.imperishable_night_caddy`. The key expires after
90 days, Tailscale's maximum. It's only needed when a site registers,
and `tofu apply` mints a new one once it expires.

Tailnet sites use `tls internal`, and Caddy's local CA uses
lotus-land-story's root, so devices that already trust that root also
trust imperishable-night's sites. The root certificate is
`modules/nixos/caddy-root.crt`, and its key is a sops secret. Caddy
signs and renews its own intermediate from them.

Some sites have no container behind them. `setup` serves, over plain
HTTP, a page that walks a device through trusting that root, along with
the root itself as `root.pem`; both come from the flake. `pihole`,
`home-assistant-5119`, and `birbs.chislan.family` proxy to devices at
home over the tailnet: mountain-of-faith, Home Assistant, and
hopeless-masquerade. `birbs.chislan.family` serves its own `robots.txt`
that disallows all crawling, since BirdNET-Pi answers every path with
links that lead crawlers in circles. `gists.kejadlen.dev` and
`files.chislan.family` serve `/var/lib/gists` and `/var/lib/files`,
which `alpha` owns so that rsync over SSH can write to them. The gists
repository's `bin/sync` fills `/var/lib/gists`, and Caddy renders its
Markdown with `_render.html`.

## PostgreSQL

PostgreSQL 17 runs from NixOS's `services.postgresql` module, the
default version for the host's `stateVersion`. It listens on localhost,
but `pg_hba.conf` admits no TCP logins. Clients connect through the
socket in `/run/postgresql` and authenticate with peer auth, which maps
the connecting process's OS user to the role of the same name, so no
role has a password. Each role reaches only the database named after it;
only the `postgres` superuser reaches every database. miniflux, its only
client, runs as the host's `miniflux` user (uid 399) with
`/run/postgresql` mounted in. postgresql recreates that directory when
it restarts, so the miniflux container's unit is part of
`postgresql.service` and restarts with it. The cluster lives in
`/var/lib/postgresql`, and [backups](backup.md) take a dump of it rather
than copying its files.

## Authelia

authelia's configuration comes from the flake, but its users don't.
`users_database.yml` lives in `/var/lib/authelia` beside its SQLite
database, so that password resets can write to it, and the repository
doesn't track it. To add a user, change a group, or disable an account,
edit the file on the host and restart `podman-authelia`. Generate a
password hash with
`podman exec -it authelia authelia crypto hash generate argon2`.
[Backups](backup.md) cover the file with the rest of `/var/lib`.

## Secrets

sops-nix decrypts `imperishable-night/secrets.sops.yml` at activation,
with the age key derived from the host's SSH key, into `/run/secrets`,
a ramfs that never reaches the disk or swap. [Backups](backup.md)
covers restic.

Containers get secrets as mounted files where the app can read them,
because podman copies a container's environment, `environmentFiles`
included, into its runtime spec and database under
`/var/lib/containers/storage`. authelia reads four secrets through its
`_FILE` variables, and the template filter fills in the SMTP username
and OIDC signing key, which have no such variable, from a second config
file. Grafana reads its SMTP password through `$__file{}` in
`grafana.ini`, and VictoriaMetrics reads the scrape config's tokens
through `credentials_file`. miniflux reads
`ADMIN_PASSWORD_FILE`.
gotosocial reads all of its settings, the OIDC client secret included,
from a config file that sops-nix renders, at `GTS_CONFIG_PATH`. Only
OpenTelemetry's variables and `TZ` stay in its environment.
paperless-ngx reads `PAPERLESS_SECRET_KEY_FILE`, but its s6 init copies
the value and the rest of the environment into
`/run/s6/container_environment`. Podman doesn't mount a tmpfs on `/run`,
so the container gets one explicitly, with `exec` because s6 runs its
services from there. Caddy, homebox, and ketchup still take environment
files, so their secrets are on disk while they run.

The file holds the following values:

| Key | Source |
|---|---|
| `authelia.<name>` | `authelia.<name>` in `host_vars/lotus-land-story.sops.yml`, for `jwt_secret`, `session_secret`, `storage_encryption_key`, `smtp_username`, `smtp_password`, and `oidc_private_key` |
| `caddy.ts_authkey` | `tofu output -raw imperishable_night_caddy_auth_key` |
| `caddy.dnsimple_token` | An account access token minted in DNSimple |
| `caddy.ca_root_key` | `caddy/pki/authorities/local/root.key` in lotus-land-story's Caddy data directory |
| `docket.fastmail_tokens.<name>` | `docket.fastmail_tokens.<name>` in `host_vars/lotus-land-story.sops.yml`; unused until docket deploys |
| `docket.sentry_dsn` | `docket.sentry_dsn` in `host_vars/lotus-land-story.sops.yml`; unused until docket deploys |
| `gotosocial.oidc_client_secret` | `gotosocial.oidc_client_secret` in `host_vars/lotus-land-story.sops.yml` |
| `grafana.smtp_password` | `grafana.smtp_password` in `host_vars/lotus-land-story.sops.yml` |
| `home_assistant.access_token` | `home_assistant.access_token` in `host_vars/lotus-land-story.sops.yml` |
| `homebox.api_key_pepper` | `openssl rand -base64 48`; rotating it invalidates homebox's API keys |
| `homebox.mailer.username` | `homebox.mailer.username` in `host_vars/lotus-land-story.sops.yml` |
| `homebox.mailer.password` | `homebox.mailer.password` in `host_vars/lotus-land-story.sops.yml` |
| `ketchup.session_secret` | `ketchup.session_secret` in `host_vars/lotus-land-story.sops.yml` |
| `linode.api_token` | `linode.api_token` in `host_vars/lotus-land-story.sops.yml` |
| `miniflux.password` | `miniflux.password` in `host_vars/lotus-land-story.sops.yml`; `alpha`'s login, which `CREATE_ADMIN` sets only if the user doesn't exist |
| `paperless_ngx.secret` | `paperless_ngx.secret` in `host_vars/lotus-land-story.sops.yml` |
| `quire.github_mirror` | `quire.github_mirror` in `host_vars/lotus-land-story.sops.yml` |
| `quire.github_auth_header` | `quire.github_auth_header` in `host_vars/lotus-land-story.sops.yml` |
| `quire.sentry_dsn` | `quire.sentry_dsn` in `host_vars/lotus-land-story.sops.yml` |
| `restic.password` | `restic.password` in `host_vars/lotus-land-story.sops.yml` |
| `restic.healthcheck` | The UUID of imperishable-night's healthchecks.io backup check |
| `syncthing.legacy_of_lunatic_kingdom.api_key` | `syncthing.legacy_of_lunatic_kingdom.api_key` in `host_vars/lotus-land-story.sops.yml` |

Edit it with `sops imperishable-night/secrets.sops.yml`. Nix only sees
files that git tracks, so commit a new or changed secrets file before
deploying.

[caddyfile]: ../imperishable-night/Caddyfile

## Access and deploys

Root login is disabled. `alpha` logs in with the keys from
`github.com/kejadlen.keys`, has passwordless sudo, and is a trusted Nix
user, so nixos-rebuild can copy closures in. The workstation evaluates
the flake and the host builds it; the [root README](../README.md) has
the deploy command.

`alpha`'s packages come from the `profile` package in the dotfiles
flake, an input that `imperishable-night/flake.lock` pins. The dotfiles
flake locks its own nixpkgs, so every machine that uses it gets the same
versions. Tools that have DotSlash files in the dotfiles' `bin/` stay
out of the profile. To pick up a dotfiles change, push it, run
`nix flake update dotfiles --flake ./imperishable-night`, and deploy.
neovim comes from neovim-nightly-overlay, whose builds aren't in a
binary cache, so a deploy that bumps it builds neovim on the host.

When the personal dashboard shows the host behind nixpkgs, follow
[Update nixpkgs](../imperishable-night/README.md#update-nixpkgs). Inputs
that follow nixpkgs build against the new revision, but `alpha`'s
packages don't change, since dotfiles locks its own.

The `dotfiles-clone` service clones the dotfiles from GitHub into
`~alpha/.dotfiles` if they aren't already there. It never pulls, so
updating the checkout is up to `alpha`. To start over, remove the
directory and run `sudo systemctl start dotfiles-clone`.

The root tofu configuration ignores changes to the instance's image and
SSH keys, since either would recreate the instance and wipe NixOS.
