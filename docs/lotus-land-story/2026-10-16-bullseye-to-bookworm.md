# Upgrading lotus-land-story to bookworm

lotus-land-story runs Debian 11 (bullseye), whose LTS window closed on
2026-08-31. The `bullseye-security` mirror went stale soon after, and every
`apt update` on the host has failed since — unattended-upgrades included,
so the box has taken no security patches since LTS ended. This plan moves
it to Debian 12 (bookworm) in one hop. A later hop to trixie (13) is out
of scope; bookworm's own LTS window runs to mid-2028.

These are two changes, and the repository changes land first: the postgres
tasks currently hardcode `/etc/postgresql/13`, and the replacements point
at 15, which only exists after the upgrade. Commit before, deploy after.

What rides along without changes: Grafana, VictoriaMetrics, Caddy,
Authelia, and the rest run as containers, and Vector runs as a
`timberio/vector:*-debian` image. After the upgrade, `rake ansible`
re-targets the facts-based deb822 repositories (docker, tailscale, redis)
to bookworm on its own.

## What bookworm breaks for this setup

- `docker-compose` (Compose v1) was removed from bookworm. Nothing on the
  host uses it — the playbooks drive Docker through `community.docker`,
  and `playbooks/docker.yml` installs `docker-compose-plugin` — so the
  package comes off `main.yml`'s "Install ansible requirements" list.
- Four tasks hardcode `/etc/postgresql/13`: the `listen.conf` path in
  `main.yml`, `data_directory` and the tuning loop in `postgres.yml`, and
  `pg_hba.conf` in `miniflux.yml`. After the migration the cluster lives
  under `/etc/postgresql/15`, so those paths become 15.
- The 13 cluster's data already sits on the Linode volume at
  `/mnt/lotus-land-story/postgresql`, and stays there through the
  migration.

## Before the upgrade

1. Run `backup.sh` by hand and check it reports success: restic snapshots
   of the volume plus a fresh `pg_dumpall`, mirrored to the secondary
   repository.
2. Take a Linode snapshot of the disk. That snapshot is the whole-box
   rollback.
3. Check space: `df -h /` and `du -sh /mnt/lotus-land-story/postgresql`.
   The dump/restore below needs room for one SQL dump on the root disk.

## Upgrade, on the host

1. Rewrite `/etc/apt/sources.list`: `bullseye` becomes `bookworm`,
   `bullseye-updates` becomes `bookworm-updates`, and the security entry
   becomes `deb http://mirrors.linode.com/debian-security
   bookworm-security main` — bookworm dropped the `/updates` suffix.
2. Re-target the third-party one-line repositories the same way, `sed -i
   s/bullseye/bookworm/ /etc/apt/sources.list.d/*.list`, so bullseye
   builds don't constrain the dependency solve. `rake ansible` later
   replaces these files with deb822 sources.
3. `apt update && apt upgrade` (minimal first, no new packages), then
   `apt full-upgrade`. Postgres stays at 13: the installed binaries
   remain, they are just absent from the bookworm archive. The upgrade
   also installs postgresql-15, the new release default, with an empty
   15 cluster on another port.
4. Reboot for the new kernel.

## Postgres, 13 to 15

The databases are small and `backup.sh` proves a nightly `pg_dumpall`,
so dump-and-restore into a fresh cluster keeps `data_directory` on the
volume without a copy dance. `pg_upgradecluster` would work too, but it
would land the 15 data on the root disk and need a second move to return
it to the volume.

1. `sudo pg_ctlcluster 13 main stop`, then dump:
   `sudo -u postgres pg_dumpall > /tmp/all.sql`.
2. Drop the empty cluster the upgrade created —
   `sudo pg_dropcluster 15 main` — and create the real one on the
   volume: `sudo pg_createcluster 15 main -d
   /mnt/lotus-land-story/postgresql-15 --start`.
3. Restore: `sudo -u postgres psql -f /tmp/all.sql postgres`.
4. Run `rake ansible`. The repository changes apply: 15 paths,
   `data_directory` pointing at `postgresql-15`, the tuning values
   (already computed for 15 — see the pgtune comment in `postgres.yml`),
   `listen.conf`, and the `pg_hba.conf` rules.
5. Keep the stopped 13 cluster until the verification below passes, then
   `sudo pg_dropcluster 13 main` and remove the old
   `/mnt/lotus-land-story/postgresql` directory.

## Verify

- `apt update` completes clean; `systemctl status apt-daily-upgrade`
  shows unattended-upgrades running again.
- `pg_lsclusters` shows 15 `main` online, and the postgres-backed
  containers connect — miniflux first, since its `pg_hba.conf` rules were
  just re-applied.
- `docker ps` shows the containers back up after the reboot;
  the Grafana network panels render cadvisor data.
- `backup.sh` succeeds against the 15 cluster.

## Cleanup and rollback

After the first full `rake ansible`, delete the sed-edited `docker.list`
from `/etc/apt/sources.list.d/`: `playbooks/docker.yml` writes the deb822 `docker.sources`
and only removes the other historical filename, so the sed-edited
one-liner would configure Docker twice. (The deeper fix is the existing
"consolidate this into the other playbook" TODO in `main.yml`.)

To roll back, restore the Linode snapshot and redeploy the pre-upgrade
commit. In place, starting the 13 cluster again reverses the database
step while it still exists.

## Open questions

- Should `main.yml` start managing the distro sources (`sources.list`)
  as deb822, the way it manages the third-party repositories? The
  bullseye leftovers survived because nothing owned that file.
- Chain on to trixie now, or let bookworm settle first? The plan assumes
  one hop, then reassess.

[bookworm-upgrading]: https://www.debian.org/releases/bookworm/amd64/release-notes/ch-upgrading.html
[lts]: https://wiki.debian.org/LTS
