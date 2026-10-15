# legacy-of-lunatic-kingdom

The NAS — "lolk" for short. A Beelink ME mini with three 2 TB NVMe drives
in RAID5, running Debian trixie on the tailnet. It hosts the secondary
restic repository and syncthing data, and is growing into running
services: caddy today, immich and jellyfin planned.

For first-time setup, see the [bootstrap README][readme].

[readme]: ../legacy-of-lunatic-kingdom/README.md

## Runtime model

All stateful data lives under `/mnt/data` (`data_dir` in `hosts.yml`);
each service gets a subdirectory there.

Containers run under Podman, managed by Quadlet: systemd generates a
service from each `.container` file in `/etc/containers/systemd/`, named
after the file (`caddy.container` becomes `caddy.service`). lotus-land-story
still runs Docker while it [migrates][migration], so container conventions
differ between the two hosts for now.

[migration]: lotus-land-story/2026-09-04-podman-migration.md

Containers that talk to each other join the `legacy_of_lunatic_kingdom`
podman network, so they address each other by container name — caddy will
proxy `immich:2283`, not a published host port.

## Caddy

`legacy-of-lunatic-kingdom/caddy.yml` runs the `caddy-kejadlen` image,
which includes the tailscale plugin, so caddy itself joins the tailnet.
Each site gets a dedicated ts.net hostname through the `ts` snippet in
`templates/Caddyfile`: internal TLS, `bind tailscale/<name>`, and access
logging. Adding a site is a three-line site block.

The tailscale auth key is a podman secret (`caddy_tsauthkey`), injected
env-type as `TS_AUTHKEY`. The plugin reads the key only when registering a
new node; state persists under `caddy/data/tailscale`, so an expired key
does not disturb a running container. Rotating the key in sops recreates
the secret and restarts the service.

Secret conventions going forward: env-type secrets for consumers that read
environment variables, and the default mount-type (`/run/secrets/<name>`)
for consumers that read files, such as `POSTGRES_PASSWORD_FILE` in immich's
postgres.

The unit also caps memory at 1 GB — an unbounded caddy once took
lotus-land-story down with it — and publishes `:2019` so VictoriaMetrics
can scrape caddy's metrics endpoint.

## Services

| Service | How it runs | Defined by |
|---|---|---|
| caddy | Quadlet container | [caddy.yml][caddy] |
| syncthing | Debian package, `syncthing@syncthing.service` | [syncthing.yml][syncthing] |
| restic repository | sftp directory under the `restic` user | [main.yml][main] |
| node-exporter | Debian package, with apt and systemd collectors | [main.yml][main] |
| journal-upload | ships journald to VictoriaLogs on lotus-land-story | [journal-upload.yml][journal] |
| unattended-upgrades | Debian package, weekly apply with security-only origins | [unattended-upgrades.yml][upgrades] |
| tailscale | Debian package | [tailscale.yml][tailscale] |

[caddy]: ../legacy-of-lunatic-kingdom/caddy.yml
[syncthing]: ../playbooks/syncthing.yml
[main]: ../legacy-of-lunatic-kingdom/main.yml
[journal]: ../playbooks/journal-upload.yml
[upgrades]: ../playbooks/unattended-upgrades.yml
[tailscale]: ../playbooks/tailscale.yml

## Observability

VictoriaMetrics on lotus-land-story scrapes lolk over the tailnet:
node-exporter on `:9100` and syncthing on `:8384` (see
[scrape.yml][scrape]). journald ships to VictoriaLogs through
journal-upload, which carries caddy's JSON access logs. Caddy's `:2019`
endpoint is published for the same treatment once it joins a scrape job.

[scrape]: ../lotus-land-story/templates/scrape.yml

## Backup role

lotus-land-story's daily backup mirrors every restic snapshot into the
secondary repository on lolk, which is append-only — snapshots accumulate
without pruning. The full flow lives in [backup.md][backup].

[backup]: backup.md
