# Migrating from lotus-land-story to imperishable-night

lotus-land-story is a shared Linode 4 GB running Debian 11. It has two
problems that an in-place fix handles badly:

- It is short on memory. Over 14 days, available memory averaged 0.59 GB
  and bottomed out at 60 MB, with half a gigabyte in swap.
- Its OS is out of support. Bullseye's LTS ended on 2026-08-31, and the
  planned move to podman needs two OS upgrades first
  ([podman migration](../lotus-land-story/2026-09-04-podman-migration.md),
  [bookworm upgrade](../lotus-land-story/2026-10-16-bullseye-to-bookworm.md)).

imperishable-night replaces it: a shared Linode 8 GB (4 vCPU, 8 GB RAM,
160 GB disk) running NixOS, with every service as a podman container
through `virtualisation.oci-containers`. Services move over one at a time
while lotus-land-story keeps serving the rest. There is no single
cutover.

The move is lift-and-shift. Each container keeps its image, tag, and
environment. Replacing containers with native NixOS modules is out of
scope.

## Bootstrap the host

The root tofu configuration creates the instance in `us-west` from a
stock Debian image as a managed `linode_instance` resource, and a second
step replaces Debian with NixOS. The NixOS configuration lives in
a flake under `imperishable-night/`.

sops-nix decrypts secrets with an age key that `ssh-to-age` derives from
the host's SSH key. Add that age key as a recipient on the secrets the
host needs. Those secrets are the same ones Ansible reads from
`host_vars/lotus-land-story.sops.yml` today.

Where the Nix tooling runs is undecided. The two options differ in
whether the workstation needs Nix installed.

### Option A: Nix only on the host

The workstation needs no Nix. A tofu `remote-exec` provisioner runs
nixos-infect on the Debian instance, which converts it to NixOS in place.
nixos-infect is a community script and less maintained than
nixos-anywhere. Read the host's SSH key after the conversion to derive
its age key.

To deploy, push the repository, SSH in, and run the following on the
host:

```sh
nixos-rebuild switch --flake <repository>#imperishable-night
```

Evaluation and builds both happen on the host, so a mistake in the
configuration surfaces there instead of on the workstation.

### Option B: Nix on the workstation

The workstation has Nix installed, though not NixOS. nixos-anywhere
replaces Debian over SSH. Pass a pre-generated SSH host key with
`--extra-files` so the age key exists before first boot.

To deploy, run the following from the repository root:

```sh
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ./imperishable-night#imperishable-night \
  --target-host imperishable-night --build-host imperishable-night
```

The workstation evaluates the configuration and the host builds it, so
macOS needs no Linux builder. nixos-rebuild on macOS may also need
`--fast` or `--no-reexec`, which is unverified.

### Base configuration

The base configuration covers the following:

- Tailscale, joined as `imperishable-night`
- node-exporter, added to the scrape config in
  `lotus-land-story/templates/scrape.yml`
- PostgreSQL and the restic backup job (see
  [Back up both hosts](#back-up-both-hosts))
- Caddy, running the same `ghcr.io/kejadlen/caddy-kejadlen` image with
  no sites yet (see [Move ingress with each service](#move-ingress-with-each-service))
- A firewall that trusts `tailscale0` and opens 80 and 443 publicly

## Move ingress with each service

Each site moves to imperishable-night's Caddy along with its service.
lotus-land-story's Caddy doesn't proxy to imperishable-night's
containers. That would mean publishing every container port on the host,
and several collide: gitea, quire, docket, dockhand, and grafana all
listen on 3000. With a Caddy on each host, every upstream stays a
container name on that host's own network.

How a site moves depends on how Caddy serves it:

- A tailnet site is its own tailscale node through caddy-tailscale
  (`bind tailscale/rss`). Remove the site from lotus-land-story's
  Caddyfile, delete its machine in the tailscale admin console, and let
  imperishable-night's Caddy register the same name. If the old machine
  still exists, tailscale registers the new one as `rss-1` instead.
- A public site needs its A record in `dns.tf` pointed at
  imperishable-night instead of `local.lotus_land_story`. Lower
  the record's TTL a day ahead. Copy the site's certificate from
  lotus-land-story's Caddy data directory first, so imperishable-night
  serves it without waiting on ACME. While the record propagates, point
  the old site at imperishable-night's Caddy on 443 so that clients
  still resolving the old address reach the new host:

  ```caddy
  hey.kejadlen.dev {
  	reverse_proxy https://imperishable-night {
  		header_up Host {host}
  		transport http {
  			tls_server_name {host}
  		}
  	}
  }
  ```

  This is one Caddy-to-Caddy hop on 443, so no container ports are
  involved. Remove the site from lotus-land-story once the old TTL has
  passed.

A tailnet site is down between the old Caddy dropping it and the new
Caddy registering it. A public site with the bridge above has no gap
beyond the service's own downtime.

Two Caddyfile values are host-specific on imperishable-night:
`trusted_proxies` comes from the podman network's subnet instead of the
docker network's, and `TS_AUTHKEY` needs a reusable key so that
registering each new site doesn't take a new key.

## Move a service

Follow these steps for each service:

1. Define the container and its Caddy site in the flake, with the image
   tag and environment from its playbook in `lotus-land-story/`.
2. Deploy imperishable-night with the container stopped and the site
   left out.
3. Stop the container on lotus-land-story, and remove its site from
   lotus-land-story's Caddyfile.
4. Copy the service's data:
   - For files, rsync `/mnt/lotus-land-story/<service>/`.
   - For a database, `pg_dump` that one database and restore it on
     imperishable-night.
5. Start the container on imperishable-night.
6. Move the site, as described in
   [Move ingress with each service](#move-ingress-with-each-service).
7. Verify the service, then remove it from lotus-land-story's
   `main.yml`.

Restoring the data from restic instead of rsyncing it also works, and it
tests the backups along the way.

### Shared state

miniflux and ketchup share lotus-land-story's PostgreSQL 13
cluster. Each database moves with its service. Moving one database at a
time also spreads the jump from 13 to the newer nixpkgs PostgreSQL across
services instead of doing it all at once.

paperless-ngx is the only redis user, so redis moves with it.

## Order of moves

Move the services in the following order, starting with those whose
breakage costs least:

1. Personal services: ketchup, docket, quire, irc (soju), and homebox.
2. PostgreSQL-backed services: miniflux.
3. Family-facing services: calibre-web, paperless-ngx with redis, and
   pro-tacts.
4. Public services: gitea with anubis, and gotosocial. gitea also has a
   pihole record in the root `main.tf` that points `git.kejadlen.dev` at
   lotus-land-story's tailnet address, so repoint it at the same time.
5. authelia.
6. Observability: VictoriaMetrics, VictoriaLogs, VictoriaTraces, Grafana,
   Vector, and the OpenTelemetry collector.
7. Sites that only Caddy serves: `setup`, `gists`, `files`, `birbs`,
   `pihole`, and the two Home Assistant proxies. The file-serving sites
   need their directories under `/mnt/lotus-land-story/caddy/data`
   copied along with them.

dockhand and cadvisor talk to the Docker socket. Check whether each
works against podman's Docker-compatible socket before moving it.

## Move gotosocial

gotosocial federates as `hey.kejadlen.dev`, and other servers know the
account by that host and by the signing keys in gotosocial's database.
`GTS_HOST` stays the same and the SQLite database moves intact, so the
account's identity is unchanged. This is a server relocation, not an
ActivityPub account move, and followers don't need to do anything.

The open question is what federation traffic does during the outage:

- Inbound deliveries fail while gotosocial is down. Remote servers retry
  failed deliveries with backoff; Mastodon retries for days, but other
  servers' retry windows are unverified.
- Outbound deliveries that gotosocial has queued but not sent may be
  lost when it stops, if its queue lives only in memory. Whether it does
  is unverified, so avoid posting right before the move.

To keep the outage short, follow these steps:

1. Lower the TTL on `hey.kejadlen.dev` a day ahead.
2. Copy `/mnt/lotus-land-story/gotosocial/` to imperishable-night while
   gotosocial is still running, so the final copy only transfers what
   changed.
3. Stop gotosocial, then back up the database with
   `sqlite3 ... '.backup ...'` as a rollback point, as
   `lotus-land-story/gotosocial.yml` already does before upgrades.
4. Rsync the data directory again, then start gotosocial on
   imperishable-night.
5. Switch the old site to the Caddy-to-Caddy bridge, then point the A
   record at imperishable-night.

Logging in to gotosocial goes through authelia over
`https://auth.kejadlen.dev`, which is public, so gotosocial can move
before authelia does.

## Move authelia

authelia is the OIDC provider for Tailscale login, so an authelia
outage blocks anyone from signing in to the tailnet. Its move has three
constraints:

- The issuer URL stays `https://auth.kejadlen.dev`.
- The OIDC signing key and storage encryption key stay the same.
- The SQLite database, `users_database.yml`, and secrets move intact,
  copied while the container is stopped.

Moving `auth.kejadlen.dev` and `auth.chislan.family` takes an A record
change, so lower their TTLs a day ahead to keep the login outage short.

## Back up both hosts

lotus-land-story's daily restic run covers only its own volume. Before
the first stateful service moves, imperishable-night needs its own
restic job against the repository on legacy-of-lunatic-kingdom, with a
distinct host tag. Use NixOS's `services.restic.backups`. It has the
same phases as `lotus-land-story/templates/backup.sh`, with
`podman exec` replacing `docker exec` for the pro-tacts dump. Update
[backups](../backup.md) when it lands.

## Point observability at the old stack

Until the observability stack moves, imperishable-night's Vector ships
logs to VictoriaLogs on lotus-land-story, and lotus-land-story's
VictoriaMetrics scrapes imperishable-night. When the stack moves, either
copy the VictoriaMetrics data directory or let the old history age out.

## Retire lotus-land-story

Once its Caddyfile serves no sites, lotus-land-story is idle. After a
quiet period, take a final restic snapshot of it. Then remove it from
`hosts.yml` and the scrape config.

The live tofu configuration doesn't manage lotus-land-story. The root
`main.tf` only looks it up with data sources, and the separate
configuration in `lotus-land-story/` has had no state changes since
April 2023, so it still describes a Nanode with a 10 GB volume. Delete the
instance and its volume in Linode directly. Then remove the
`lotus-land-story/` tofu files and the `lotus_land_story` data sources and
local from the root `main.tf`.
