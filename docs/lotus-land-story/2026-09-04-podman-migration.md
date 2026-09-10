# Migrating lotus-land-story to podman + systemd

Target state: every container is a Quadlet unit in `/etc/containers/systemd/`,
generated into systemd services, with Ansible templating the `.container` files
instead of driving `community.docker.docker_container`. Rootful podman. Docker
is removed at the end.

Services move a few at a time, with docker and podman running side by side
throughout.

## The blocker

Bullseye's podman is 3.0.1. Quadlet arrived in podman 4.4, and `podman generate
systemd` — the 3.x-era alternative — is deprecated in podman 5. There is no
supported backport path to a Quadlet-capable podman on Debian 11.

So this is two migrations stacked: bullseye → bookworm → trixie first, then
docker → podman. Trixie ships podman 5.4, netavark, and a 6.12 kernel.

Bullseye's LTS ended 2026-08-31, so the OS half needs doing regardless.

## The seam

The one thing that makes an incremental cutover hard: podman's aardvark-dns and
docker's embedded DNS don't share a namespace. A container on podman cannot
resolve `gitea` on the docker bridge, and vice versa. Every cross-runtime hop has
to go through the host gateway instead — a published port on one side,
`host.docker.internal` or `host.containers.internal` on the other.

That would be miserable to maintain by hand, except that every config holding a
container name is already an Ansible template or inline content. So the seam
becomes one var and one macro.

Give each service a runtime, a container port, and a temporary host port:

```yaml
services:
  miniflux:     { runtime: docker, port: 8080, host_port: 18080 }
  victoria-logs: { runtime: docker, port: 9428, host_port: 9428 }  # already published
  # ...
```

And render addresses through a macro that compares the target's runtime to the
consumer's:

```jinja
{% macro upstream(name, from='caddy') %}
{%- set t = services[name] -%}
{%- if t.runtime == services[from].runtime -%}
{{ name }}:{{ t.port }}
{%- elif services[from].runtime == 'docker' -%}
host.docker.internal:{{ t.host_port }}
{%- else -%}
host.containers.internal:{{ t.host_port }}
{%- endif -%}
{% endmacro %}
```

Migrating a service is then: flip its `runtime` to `podman`, add its `host_port`
to the Quadlet unit, rerun. Every consumer follows automatically.

Distinct host ports matter — `gitea`, `grafana`, `quire`, and `dockhand` all
listen on 3000 internally, so they cannot all publish 3000 on the host.

## Who addresses whom

Two containers address nearly everything else, and both are template-driven,
which is what makes the incremental order tractable.

`caddy`, via `templates/Caddyfile`, reaches authelia:9091, cadvisor:8080,
grafana:3000, victoria-logs:9428, victoria-traces:10428, victoria-metrics:8428,
quire:3000, soju:3030, miniflux:8080, ketchup:9292, calibre-web:8083,
paperless-ngx:8000 and :5555, homebox:7745, dockhand:3000, gitea:3000,
anubis:8923, and gotosocial:8080.

`victoria-metrics`, via `templates/scrape.yml`, reaches anubis:9090,
authelia:9959, cadvisor:8080, caddy:2019, gitea:3000, gotosocial:9464,
grafana:3000, miniflux:8080, paperless-ngx:5555, and victoria-logs:9428.

Everything else is a handful of edges: `anubis` → gitea:3000 (a `TARGET` env in
`gitea.yml`), `gitea-runner` → gitea:3000 plus job containers on the network,
`vector` → victoria-logs:9428 (a sink URI in `templates/vector.yml`), and
`grafana` → victoria-logs and victoria-metrics (inline datasource provisioning in
`grafana.yml`).

Caddy and victoria-metrics therefore move **last**, so every other service moves
alone. `templates/vector.yml` is currently written with `ansible.builtin.copy`
and needs switching to `template` to participate.

Four host ports are already published, so those services cost nothing extra
during the window: caddy's 80/443/443-udp/2019, victoria-logs' 514 and **9428**,
gitea's 2222, and soju's 6697.

## Phase 1: OS upgrade

Two dist-upgrades, verified separately, with docker running untouched throughout.
Take a Linode backup before each — it's the only rollback.

Postgres moves 13 → 15 → 17 via `pg_upgradecluster` at each step. Confirm which
databases actually live there before planning the window; miniflux is the only
one visible in the playbooks, which would make this small. The `data_directory`
override to `/mnt/lotus-land-story/postgresql` means the new cluster needs the
same treatment after each upgrade.

Version-pinned postgres paths are hardcoded in four places and all need
parameterizing to a `postgres_version` var first:

| File | Path |
| --- | --- |
| `main.yml:50` | `/etc/postgresql/13/main/conf.d/listen.conf` |
| `postgres.yml:23` | `/etc/postgresql/13/main/postgresql.conf` |
| `postgres.yml:46` | `/etc/postgresql/13/main/postgresql.conf` |
| `miniflux.yml:23` | `/etc/postgresql/13/main/pg_hba.conf` |

Redis and docker both come from vendor repos keyed to
`ansible_distribution_release`, so they follow the upgrade without playbook
changes. Re-check that `packages.redis.io` publishes trixie before starting.

The postgres tuning block in `postgres.yml` is sized for 4 GB, which matches the
host. Leave it.

## Phase 2: foundation, with nothing cut over

Install podman — but not `podman-docker`, since the two runtimes need to stay
distinguishable. Enable `podman.socket`. Graphroot stays at the default
`/var/lib/containers` on `/`, which has 67 GB free; the docker graphroot is 28 GB
on the 40 GB data volume at 75% full.

Define the podman network as a Quadlet `.network` file with a **fixed subnet and
gateway** rather than letting podman allocate. This is the single biggest
simplification available, and it deletes:

- Two copies of the `ip -4 -o addr show docker0 | awk` shell-out, in `docker.yml`
  and again in `redis.yml` with a `TODO Figure out how to de-duplicate this` on
  top of it.
- Seven `community.docker.docker_network` register-and-read-`IPAM.Config[0].Subnet`
  dances, in `caddy.yml`, `gotosocial.yml`, `logs.yml`, `irc.yml`, `miniflux.yml`,
  `metrics.yml`, and `security.yml`.

Then dual-stack the host so both runtimes work at once: postgres
`listen_addresses` and redis `bind` take both the docker0 address and the fixed
podman gateway, and ufw allows both subnets.

Finish the phase by introducing the `services` var and `upstream()` macro into
the Caddyfile, scrape.yml, vector.yml, and grafana's datasource provisioning with
**every service still marked `docker`**. Rendered output should be byte-identical
to today. That no-op run is the safety check on the whole mechanism — verify it
before anything actually moves.

## Phase 3: unit-authoring conventions

Ansible pattern per service becomes `ansible.builtin.template` writing
`/etc/containers/systemd/<name>.container`, notifying a handler that runs
`systemctl daemon-reload` and restarts the unit. `community.docker` drops out;
`containers.podman` is only needed if something must be driven imperatively,
which Quadlet mostly avoids.

`calibre-web.service` and `victoria-traces.service` are already hand-rolled
systemd units wrapping `docker run --rm`, so they're the shape the rest become.

Applies broadly:

- `restart_policy: unless-stopped` → `Restart=always` plus
  `[Install] WantedBy=multi-user.target`.
- Podman needs fully-qualified image names. Short names to fix: `grafana/grafana`,
  `miniflux/miniflux`, `timberio/vector`, `superseriousbusiness/gotosocial`,
  `gitea/act_runner`, and `fnsys/dockhand` all take a `docker.io/` prefix.
  `victoriametrics/victoria-metrics` and `victoria-logs` should move to `quay.io`
  while we're touching them.
- Keep `host.docker.internal` via `AddHost=host.docker.internal:host-gateway`.
  Podman offers `host.containers.internal` natively, but renaming means touching
  miniflux's `DATABASE_URL`, paperless's `PAPERLESS_REDIS`, and the scrape config
  for no gain.
- The `docker inspect --format '{{ index .Config.Labels ... }}'` version guards in
  `gitea.yml`, `gotosocial.yml`, and `homebox.yml` become `podman inspect`, same
  format string.
- `quire` and `quire-gitweb` run `latest` with `pull: always`. Quadlet equivalent
  is `AutoUpdate=registry` plus `podman-auto-update.timer`, or `Pull=newer`.
- Caddy's anonymous `caddy-config:/config` volume becomes a bind mount, which is
  what the `TODO probably put this somewhere else???` already wants.
- `After=` the network unit everywhere, plus `After=postgresql.service` for
  miniflux and `After=redis-server.service` for paperless.
- `daemon.json` dissolves: graphroot into `storage.conf`, the `local` log driver
  and its size caps into journald, and `metrics-addr` into the exporter swap in
  wave 5.

## Waves

**Wave 1 — the two that are already systemd.** `victoria-traces` and
`calibre-web` are docker-run wrappers in systemd units today, and only caddy
addresses them. Converting these validates the Quadlet toolchain while
introducing no new pattern.

**Wave 2 — simple leaves.** `ketchup`, `homebox`, `soju`, `authelia`, and
`quire-gitweb`. Caddy and scrape.yml are the only consumers; the macro covers
both.

**Wave 3 — host-service dependents.** `miniflux` and `paperless-ngx`. Both
already reach postgres and redis through `host.docker.internal`, which the
`AddHost` line preserves. See the trusted-proxies note below — these two are
where it bites first.

**Wave 4 — observability core, in order.** `victoria-logs` first, since it
already publishes 9428 and both its consumers are template-driven. Then
`victoria-metrics`, then `grafana`.

**Wave 5 — socket consumers**, once the spikes below have answers. `vector`,
`dockhand`, cadvisor → `prometheus-podman-exporter`, and `quire`.

**Wave 6 — the gitea cluster**, moved as one: `gitea`, `anubis`, and
`gitea-runner`. Client IP handling here is load-bearing in three places — the
Caddyfile's `@undefined-fantastic-object client_ip` match, anubis's rate
limiting, and fail2ban's gitea jail parsing IPs out of `/var/log/gitea.log`. Move
it late, when few cross-runtime hops remain to distort the source address.

**Wave 7 — caddy.** When caddy flips, the macro's polarity inverts for everything
behind it. If nothing else remains on docker by then, it emits plain container
names and the whole seam evaporates.

**Wave 8 — teardown.** Remove docker, delete `/mnt/lotus-land-story/docker` to
reclaim 28 GB, drop the `--exclude=/mnt/lotus-land-story/docker` line in
`templates/backup.sh`, delete `playbooks/docker.yml` and `docker.yml`, drop
`docker-compose` and `python3-docker` from `main.yml`'s package list, and retire
cadvisor. `templates/docker.list` is already dead — `playbooks/docker.yml` moved
to `deb822_repository` and stopped using it, and it still references an
`arch.stdout` var that no longer exists.

Then strip the scaffolding: every unit's temporary `host_port` publication comes
back out, and the `services` var collapses to whatever the fixed-subnet work
still needs. This cleanup pass is the price of going incremental, and it's worth
budgeting for rather than discovering.

`main.yml` omits `gitea.yml`, `authelia.yml`, `calibre-web.yml`, `irc.yml`,
`metrics.yml`, `paperless-ngx.yml`, `dockhand.yml`, and `setup.yml`. Less urgent
when services move a few at a time, but fold them in before the end so a full run
means something again.

## Two things that bite during the window

**Vector goes half-blind.** Its `docker_logs` source sees only the runtime whose
socket it watches, so the moment anything moves, that container's logs stop
arriving — or every still-docker container's logs do. Fix is to run two sources,
one on `docker.sock` and one on `podman.sock`, both feeding the existing
transforms, and drop the docker one in wave 8. The per-container branching in
`templates/vector.yml` keys on `.container_name`, which both sources populate, so
the transforms themselves don't change. Do this in phase 2, before wave 1.

The same split applies to metrics: cadvisor sees docker containers,
`prometheus-podman-exporter` sees podman ones, so both get scraped until wave 8.
Their metric names differ, so Grafana panels built on cadvisor's `container_*`
series need rework regardless.

**Trusted proxies stop matching.** While caddy is on docker and a service is on
podman, caddy's requests arrive at that service through the host gateway rather
than off a shared bridge, so the source address is no longer inside the subnet
that `trusted_proxies`, `TRUSTED_REVERSE_PROXY_NETWORKS`, `METRICS_ALLOWED_NETWORKS`,
and `GTS_TRUSTED_PROXIES` are configured for. Widen them to cover private ranges
for the duration and tighten back in wave 8. Verify what the source address
actually is on the first wave-3 service rather than predicting it.

## Open questions

- Which databases actually live in postgres, and how big are they? Determines the
  size of the phase 1 window.
- What does quire use the docker socket for? It runs as the `quire` user in the
  `docker` group, and rootful podman has no group equivalent — the answer decides
  between a sudoers rule and a rootless podman user.
- Does `act_runner` drive podman's compat socket well enough to spawn job
  containers on a named network? The comment at `gitea.yml:113` records why DinD
  was rejected; if the socket route fails, the fallback is keeping docker
  installed for the runner alone, which delays wave 8 without blocking anything.
- Does `dockhand` work against the compat socket?
- Does caddy-tailscale get TUN under rootful podman without extra capability
  work?
- Which Grafana panels read cadvisor series?
