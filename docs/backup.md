# Backups

imperishable-night backs up daily with restic into a repository on
legacy-of-lunatic-kingdom. That repository is the only long-term copy:
losing lolk loses the backup history along with it.

The repository also holds lotus-land-story's snapshots from before it
retired. After its final snapshot, a one-time `forget` thinned them to
dailies for its last month, monthlies for its last year, and yearlies
before that. Nothing prunes them after that.

imperishable-night also has Linode's Backups service enabled, which
keeps about two weeks of whole-disk backups.

## The daily run

NixOS's `services.restic.backups.daily` runs as the
`restic-backups-daily` service at 03:00 UTC, and catches up on boot if
the host was down then.

The unit first runs `restic-backups-victoria-metrics`, which has no
timer of its own. That unit snapshots VictoriaMetrics with `vmbackup`
into `/var/lib/victoria-metrics-backup`, backs the snapshot up tagged
`victoria-metrics`, and forgets this host's `victoria-metrics` snapshots
older than 7 days. `vmbackup` rewrites as many parts as VictoriaMetrics
merges, so a longer retention would keep gigabytes of churn. If the
unit fails, `restic-backups-daily` doesn't start, and healthchecks.io
reports the missed ping.

Before backing up, the daily unit runs the following steps, and any
failure fails the run:

1. Dumps pro-tacts' database with `podman exec pro-tacts rake db:dump`.
2. Dumps gotosocial's SQLite database with `VACUUM INTO` into a
   temporary file, then moves it over
   `/var/lib/gotosocial/backup/sqlite.db`. The
   [SQLite backup evaluation](research/2026-11-12-sqlite-backups.md)
   covers why it doesn't use `.backup`.
3. Writes an exclude file that drops every directory in
   `/var/lib/gotosocial/data/` except the local accounts', since the
   rest is remote media that gotosocial re-fetches. The run fails if the
   dump lists no local accounts.
4. Copies Grafana's SQLite database with `VACUUM INTO` into a temporary
   file, then moves it over `/var/lib/grafana-backup/grafana.db`. The
   database uses a rollback journal rather than WAL, so the copy blocks
   Grafana's writes while it runs, and waits up to 30 seconds for a
   write in progress to finish.
5. Writes `pg_dumpall` output to
   `/var/lib/postgresql-dump/pg_dumpall.sql`. A failed dump leaves the
   previous dump in place.

The unit then backs up `/var/lib`, tagged `long-term`, excluding
podman's `/var/lib/containers`, the live PostgreSQL cluster in
`/var/lib/postgresql`, Grafana's live `grafana.db` and its journal,
gotosocial's remote media, and the data
directories of VictoriaMetrics, VictoriaLogs, and VictoriaTraces, along
with the VictoriaMetrics snapshot. Then it runs
`unlock` and `forget --prune` on its `long-term` snapshots, keeping
daily for one month, weekly for three months, monthly for two years, and
yearly forever. The prune is limited to `--host=imperishable-night`, so
it never touches lotus-land-story's snapshots. Backup and prune both
pass `--retry-lock=30m`, so a run waits out another client's exclusive
lock instead of failing.

The unit pings its own healthchecks.io check: `/start` before the
backup, then success or `/fail` from `$SERVICE_RESULT` after it stops.
It then pushes `backup_success`, `backup_duration_seconds`, and
`backup_completed_timestamp` to VictoriaMetrics with
`host="imperishable-night"`, but no per-phase durations, since the
module runs its commands without breadcrumbs. The personal dashboard's
backup panels show one series per host. Its backups tile only checks the
hosts listed in its query, so a host that starts backing up needs adding
there. The password and check UUID come from
`imperishable-night/secrets.sops.yml`.

## Repository

`sftp:restic@legacy-of-lunatic-kingdom:/mnt/data/restic`, defined in
imperishable-night's configuration. It lives under a `restic` system
user, reachable by SSH keys for imperishable-night (its SSH host key)
and 1password (manual restores). lolk's playbook
(`legacy-of-lunatic-kingdom/main.yml`) sets up the user, keys, and
directory. imperishable-night pins lolk's host key in
`programs.ssh.knownHosts`, so its sftp connection fails closed on an
unknown key. The password is stored in
`imperishable-night/secrets.sops.yml`.

## Verifying a run

```sh
ssh imperishable-night sudo systemctl start restic-backups-daily
ssh imperishable-night journalctl -u restic-backups-daily
```
