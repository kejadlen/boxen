# Migrating from lotus-land-story to imperishable-night

lotus-land-story is a shared Linode 4 GB running Debian 11. It has two
problems that an in-place fix handles badly:

- It is short on memory. Over 30 days, used memory averaged 3.5 GB and
  peaked at 4.05 GB, with half a gigabyte in swap. paperless-ngx is
  stopped to make room.
- Its OS is out of support. Bullseye's LTS ended on 2026-08-31, and the
  planned move to podman needs two OS upgrades first
  ([podman migration](../lotus-land-story/2026-09-04-podman-migration.md),
  [bookworm upgrade](../lotus-land-story/2026-10-16-bullseye-to-bookworm.md)).

imperishable-night replaces it: a shared Linode 8 GB (4 vCPU, 8 GB RAM,
160 GB disk) running NixOS, with every service as a podman container
through `virtualisation.oci-containers`. Services move over one at a
time while lotus-land-story keeps serving the rest. There is no single
cutover.

The 8 GB size comes from lotus-land-story's usage with every service
running, paperless-ngx included. Containers average 2.8 GB according to
cadvisor, and PostgreSQL, Docker, and the OS bring the host to about 3.6
GB. gotosocial, gitea, and pro-tacts each spike to two or three times
their average, and each Gitea Actions job adds up to 530 MB. NixOS also
builds on the host, which takes an estimated 1 to 2 GB more during a
deploy. That leaves about 2 GB of headroom at worst. CPU hit 93% of 2
vCPU at the 99th percentile, so the extra cores matter too. The 44 GB of
data fits on the local disk.

The move is lift-and-shift. Each container keeps its image, tag, and
environment. Replacing containers with native NixOS modules is out of
scope.

## Bootstrap the host

The root tofu configuration creates the instance in `us-west` from a
stock Debian image as a managed `linode_instance` resource, and a second
step replaces Debian with NixOS. The NixOS configuration lives in
a flake under `imperishable-night/`.

sops-nix decrypts secrets with an age key that `ssh-to-age` derives from
the host's SSH key. The host's secrets live in their own file,
`imperishable-night/secrets.sops.yml`, encrypted to that key and the
workstation's. Each secret is copied there from
`host_vars/lotus-land-story.sops.yml` when its service moves, so the
host never holds secrets for services it doesn't run.

The Nix tooling runs on the workstation, which has Nix installed, though
not NixOS. The [deploy tooling](2026-10-20-deploy-tooling.md) comparison
covers why NixOS. nixos-anywhere replaces Debian over SSH. Derive the
age key from the host key that NixOS generates on first boot, with
`ssh-keyscan` piped into `ssh-to-age`.

[imperishable-night](../imperishable-night.md) covers the boot setup,
install, and deploys.

### Base configuration

The base configuration covers the following:

- Tailscale, joined as `imperishable-night`
- node-exporter, which the `linode` job in
  `lotus-land-story/templates/scrape.yml` already discovers
- cadvisor against podman's socket, scraped with its `instance`
  relabeled to `imperishable-night:8080` like lotus-land-story's
- PostgreSQL and the restic backup job (see
  [Back up both hosts](#back-up-both-hosts))
- Caddy, running the same `ghcr.io/kejadlen/caddy-kejadlen` image with
  no sites yet (see
  [Move ingress with each service](#move-ingress-with-each-service))
- A firewall that trusts `tailscale0` and opens 80 and 443 publicly

## Move ingress with each service

Each site moves to imperishable-night's Caddy along with its service.
lotus-land-story's Caddy doesn't proxy to imperishable-night's
containers. That would mean publishing every container port on the host,
and several collide: gitea, quire, docket, and grafana all
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
   tag and environment from its playbook in `lotus-land-story/`. Give
   the container its own entry in `podmanNetworks`, and add that network
   to Caddy's.
2. Deploy imperishable-night with the container stopped and the site
   left out.
3. Stop the container on lotus-land-story, and remove its site from
   lotus-land-story's Caddyfile.
4. Copy the service's data:
   - For files, rsync `/mnt/lotus-land-story/<service>/` with
     `--delete`, so that nothing already in the target directory
     survives.
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

miniflux is the only user of lotus-land-story's PostgreSQL 13 cluster,
so its database is the only one to move. Restoring it on
imperishable-night also jumps it from 13 to the newer nixpkgs
PostgreSQL.

paperless-ngx is the only redis user, so redis moves with it.

## Order of moves

Move the services in the following order, starting with those whose
breakage costs least:

1. Personal services: ketchup, quire, irc (soju), and homebox.
2. PostgreSQL-backed services: miniflux.
3. Family-facing services: calibre-web, paperless-ngx with redis, and
   pro-tacts.
4. Public services: gotosocial. gitea and anubis retire instead of
   moving (see
   [Retiring gitea](../lotus-land-story/2026-11-01-retiring-gitea.md)).
5. authelia.
6. Observability: VictoriaMetrics, VictoriaLogs, VictoriaTraces, and
   Grafana (see
   [Move the observability stack](#move-the-observability-stack)).
7. Sites that only Caddy serves: `setup`, `gists`, `files`, `birbs`,
   `pihole`, and the `home-assistant-5119` proxy. The file-serving sites
   need their directories under `/mnt/lotus-land-story/caddy/data`
   copied along with them. The gists repository's `bin/sync` rsyncs to
   lotus-land-story by default, so change its `GISTS_HOST` and
   `GISTS_DEST` defaults when `gists` moves.

cadvisor doesn't move: each host runs its own, and lotus-land-story's
retires with it.

docket doesn't move either. Its development is paused and nothing uses
it, so its site and playbook retire with lotus-land-story, and its data
survives only in restic. When development resumes, docket deploys on
imperishable-night with a fresh database.

## Move pro-tacts

pro-tacts serves CardDAV at `contacts.chislan.family`, the one site that
gets its certificate over DNS-01
([risk 4](../threat-model.md#4-a-linodes-secrets-reach-past-it)).
imperishable-night already holds the account-wide DNSimple token as
`caddy/dnsimple_token`, so the site's `tls` block moves unchanged. The
`contacts` A record in `dns.tf` follows the tailnet address of
imperishable-night's `pro-tacts` node.

The macOS and iOS Contacts apps sync with it, so the move must look like
the same server to them. pro-tacts builds its sync tokens, ETags, and
CTags from `contacts.db`, its hrefs are fixed relative paths, and it
picks a user's address book by `Remote-User` alone. Clients carry on
unchanged as long as the database moves intact while pro-tacts is
stopped, and `Remote-User` is still `tailscale_user`. pro-tacts doesn't
read the `X-User-Slug` header that lotus-land-story's `tsident` adds, so
the `tailscale.slugs` map stays behind.

The site's tailnet node is `pro-tacts` on imperishable-night, replacing
lotus-land-story's `contacts`, so the record's IP changes. The new name
doesn't collide with the old node, so the old one can stay up until the
move checks out. pro-tacts' traces go nowhere until VictoriaTraces
moves, since `victoria-traces` resolves only on lotus-land-story's
docker network.

Follow these steps for the move:

1. An hour ahead, apply the `contacts` record's 60-second TTL, and
   deploy imperishable-night with pro-tacts stopped.
2. Copy the site's certificate from
   `/mnt/lotus-land-story/caddy/data/caddy/certificates/` to the same
   path under `/var/lib/caddy/data/`, so the new Caddy doesn't have to
   get a certificate while clients connect.
3. Rsync `/mnt/lotus-land-story/pro-tacts/` with `--delete` while
   pro-tacts still runs, so the final copy is short.
4. Stop pro-tacts on lotus-land-story, and rsync again.
5. Deploy imperishable-night with pro-tacts and its site.
6. Apply tofu so the A record follows the `pro-tacts` node.
7. Check that the Contacts apps on macOS and iOS sync without
   re-downloading. Until they do, starting pro-tacts on lotus-land-story
   and pointing the record back is the rollback.
8. Remove the site from lotus-land-story, delete the old `contacts`
   machine in the Tailscale console, and restore the record's default
   TTL.

Avoid editing contacts during the move, so no client queues a change
against the old server.

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

The Caddy-to-Caddy bridge carries clients and servers that still resolve
the old address, so the record's TTL doesn't lengthen the outage and
doesn't need lowering. Bridged requests reach gotosocial from
lotus-land-story's tailnet address, which
`GTS_ADVANCED_RATE_LIMIT_EXCEPTIONS` exempts, so federation isn't rate
limited through the bridge.

gotosocial's metrics go unscraped until VictoriaMetrics moves, since
lotus-land-story's VictoriaMetrics reaches `gotosocial:9464` only over
its docker network.

To keep the outage short, follow these steps:

1. Deploy imperishable-night with gotosocial stopped.
2. Copy `hey.kejadlen.dev`'s certificate from
   `/mnt/lotus-land-story/caddy/data/caddy/certificates/` to the same
   path under `/var/lib/caddy/data/`. ACME challenges land on
   lotus-land-story until the record moves, so the new Caddy can't get
   its own certificate through the bridge.
3. Rsync `/mnt/lotus-land-story/gotosocial/` to `/var/lib/gotosocial/`
   with `--delete` while gotosocial is still running, so the final copy
   only transfers what changed.
4. Stop gotosocial, then back up the database with
   `sqlite3 ... '.backup ...'` as a rollback point, as
   `lotus-land-story/gotosocial.yml` already does before upgrades.
5. Rsync again, then deploy imperishable-night with gotosocial and its
   site.
6. Deploy lotus-land-story's Caddy with the Caddy-to-Caddy bridge in
   place of the old site, then apply tofu to point the A record at
   imperishable-night. Until the bridge is up, starting gotosocial on
   lotus-land-story is the rollback.
7. Remove the bridge an hour after the record changes, once DNSimple's
   default TTL has passed.

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
change. As with gotosocial, the Caddy-to-Caddy bridge carries clients
that still resolve the old address, so the TTLs don't need lowering.

`db.sqlite3` and `users_database.yml` are data, and the rsync carries
both. From then on the host owns the users database, so password resets
stick instead of reverting on the next playbook run, and
`lotus-land-story/templates/authelia_users_database.yml` retires with
the rest of lotus-land-story. `configuration.yml` comes from the flake.
Nothing in the configuration reads lotus-land-story's `secrets`
directory, so it stays behind. Sessions live in memory, so
everyone signs in to authelia again after the move, but devices already
on the tailnet stay on it. authelia's metrics go unscraped until
VictoriaMetrics moves, like gotosocial's.

Follow these steps for the move:

1. Copy the six `authelia` secrets into
   `imperishable-night/secrets.sops.yml`, then deploy
   imperishable-night with authelia stopped.
2. Copy both sites' certificates from
   `/mnt/lotus-land-story/caddy/data/caddy/certificates/` to the same
   path under `/var/lib/caddy/data/`.
3. Stop authelia on lotus-land-story, and rsync
   `/mnt/lotus-land-story/authelia/config/` to `/var/lib/authelia/` with
   `--delete`. Sign-ins to the tailnet fail from here until step 5.
4. Deploy imperishable-night with authelia started and its sites.
5. Deploy lotus-land-story's Caddy with the bridge in place of both
   sites, then apply tofu to point the A records at imperishable-night.
   Until the bridge is up, starting authelia on lotus-land-story is the
   rollback.
6. Sign in to Tailscale and to gotosocial through authelia.
7. Remove the bridge an hour after the records change, once their TTL
   has passed, and remove authelia from lotus-land-story.

## Move the observability stack

VictoriaMetrics, VictoriaLogs, VictoriaTraces, and Grafana move
together, since Grafana reads all three and VictoriaMetrics scrapes
Grafana and VictoriaLogs. `lotus-land-story/otel.yml` runs only
VictoriaTraces, so there is no OpenTelemetry collector to move. Vector
stays put, since each host runs its own. All four data directories,
about 930 MiB in all, move intact, so the dashboards keep their history.

### Networks

Grafana takes `X-WEBAUTH-USER` as a login
([risk 6](../threat-model.md#6-header-trust-apps-on-a-shared-network)),
so it shares the `grafana` network only with Caddy. That network has a
fixed subnet, which `[auth.proxy]`'s `whitelist` names. Caddy reaches
the three Victorias over `metrics`, `logs`, and `traces`, one network
each, named after their sites. Grafana and the Victorias share
`observability`, which Caddy isn't on. If Caddy and Grafana shared a
second network, Caddy's requests could arrive from an address the
whitelist rejects.

`observability` is internal, so VictoriaMetrics' only route out is
`metrics`, and Grafana's is `grafana`, for SMTP and plugin installs.
VictoriaMetrics reaches imperishable-night's own node-exporter and
cadvisor by their tailnet names, but those packets arrive on the
`metrics` bridge instead of `tailscale0`, so the firewall opens 9100 and
8080 on that bridge alone.

### Scrape config

`scrape.yml` moves into the flake. Its three secrets, the Home
Assistant token, the Linode API token, and lolk's Syncthing API key,
become sops secrets mounted as files, which the jobs read with
`credentials_file` and `bearer_token_file`. Targets that VictoriaMetrics
reached over lotus-land-story's docker network change:

| Job | Today | After the move |
|---|---|---|
| `cadvisor` | `cadvisor:8080` | `https://cadvisor`, lotus-land-story's tailnet site, still labeled `lotus-land-story:8080` |
| `caddy` | `caddy:2019` | `lotus-land-story:2019`, which its Caddy publishes |
| `docker` | `host.docker.internal:9323` | Dropped, since dockerd listens only on `docker0` |
| `postgres` | `host.docker.internal:9187` | Dropped, since lotus-land-story's cluster has held nothing since miniflux moved |

VictoriaLogs drops `-syslog.listenAddr.tcp`, whose only sender was
lotus-land-story's rsyslog over localhost.

### Log shippers

Before the stack moves, every log shipper switches to `https://logs`:
hopeless-masquerade's Vector, lolk's journal-upload in
`playbooks/journal-upload.yml`, and lotus-land-story's own Vector and
journal-upload. Each one trusts the shared Caddy root. lotus-land-story's
Caddy serves `logs` today, so the switch works ahead of the move, and
the URL survives it. lotus-land-story's rsyslog forwarding goes away,
since journald carries the same messages. `tag:birdnet`'s grant moves
from `lotus-land-story:9428` to `logs:443`. The `logs` node's address
changes when it registers on imperishable-night, so tofu applies again
after the move.

### Backups

imperishable-night's restic job takes over lotus-land-story's
VictoriaMetrics phases. `vmbackup` takes a snapshot, which gets its own
`victoria-metrics` tag and seven days of retention, and the long-term
backup excludes all three Victorias' data directories. lotus-land-story's
`backup.sh` drops those phases when its VictoriaMetrics stops.

### Steps

Follow these steps for the move:

1. Copy `grafana.smtp_password`, `home_assistant.access_token`,
   `linode.api_token`, and `syncthing.legacy_of_lunatic_kingdom.api_key`
   into `imperishable-night/secrets.sops.yml`. Then deploy
   imperishable-night with the four containers stopped and their sites
   left out.
2. Stop VictoriaMetrics, VictoriaLogs, VictoriaTraces, and Grafana on
   lotus-land-story. Deploy its Caddy without the `grafana`, `logs`,
   `metrics`, and `traces` sites, and its `backup.sh` without the
   VictoriaMetrics phases. Delete those four machines in the Tailscale
   console. Metrics and logs don't land from here until step 4.
3. Rsync each data directory with `--delete`:
   `victoria-metrics/data/`, `victoria-logs/`, `victoria-traces/`, and
   `grafana/data/` under `/mnt/lotus-land-story/` to
   `/var/lib/victoria-metrics/`, `/var/lib/victoria-logs/`,
   `/var/lib/victoria-traces/`, and `/var/lib/grafana/`. Then
   `chown -R 472:0 /var/lib/grafana`, since the image runs as uid 472
   and lotus-land-story ran it as its own `grafana` user.
4. Deploy imperishable-night with the containers started and their
   sites.
5. Apply tofu, so `tag:birdnet`'s grant follows the new `logs` node.
6. Sign in to Grafana, check that the personal dashboard shows the old
   history, check that `https://metrics/targets` shows every target up,
   and check that VictoriaLogs receives logs from every host.
7. Remove the stack from lotus-land-story's playbooks.

Until step 4, starting the containers on lotus-land-story and restoring
its sites is the rollback.

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
VictoriaMetrics scrapes imperishable-night. The data moves with the
stack (see
[Move the observability stack](#move-the-observability-stack)).

## Retire lotus-land-story

Once its Caddyfile serves no sites, lotus-land-story is idle. After a
quiet period, take a final restic snapshot of it. Then remove it from
`hosts.yml` and the scrape config.

The live tofu configuration doesn't manage lotus-land-story. The root
`main.tf` only looks it up with data sources, and the separate
configuration in `lotus-land-story/` has had no state changes since
April 2023, so it still describes a Nanode with a 10 GB volume. Delete
the instance and its volume in Linode directly. Then remove the
`lotus-land-story/` tofu files and the `lotus_land_story` data sources
and local from the root `main.tf`.
