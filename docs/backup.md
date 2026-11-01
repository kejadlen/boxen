# Backups

lotus-land-story and imperishable-night back up daily with restic into a
shared repository on legacy-of-lunatic-kingdom. That repository is the only
long-term copy: losing lolk loses the backup history along with it.

Both hosts also have Linode's Backups service enabled, which keeps about two
weeks of whole-disk backups. It skips attached volumes, so it covers
imperishable-night's data but not lotus-land-story's, which lives on the
`/mnt/lotus-land-story` volume.

## The daily run

`/etc/cron.daily/backup` on lotus-land-story (templated from
`lotus-land-story/templates/backup.sh`, owned by the play in
`lotus-land-story/backup.yml`) runs as root. cron has no MTA, so the script
sends its own output to the journal with the `backup` tag. It sets
`GOGC=20` so restic trades CPU for memory, since lotus-land-story has little
headroom and the OOM killer has taken restic mid-backup.

Each phase — unlock, pro-tacts, files, postgres, forget — logs a `> name`
breadcrumb when it starts and `< name: Ns` when it finishes, so the journal
shows where a slow or dead run sits. Each run:

1. Pings healthchecks.io `/start`, distinguishing a run that died early from
   one that never fired.
2. Dumps pro-tacts' database with `docker exec pro-tacts rake db:dump`,
   which writes under `/data` ahead of the file backup.
3. Removes stale locks from the repository, so a run killed mid-flight (for
   example, by the OOM killer) doesn't block every later prune.
4. Backs up `/mnt/lotus-land-story/`, excluding `docker/` and the live
   `postgresql*` cluster — a file-level copy of a running cluster can't be
   restored, so the dump in step 5 is the backup. The pro-tacts dump from
   step 2 rides along.
5. Backs up `pg_dumpall` output via stdin as `lotus-land-story.sql`.
6. Runs `forget --prune` with retention of daily for one month, weekly for
   one year, monthly forever.

An exit trap pings healthchecks.io with success or failure and pushes
`backup_*` metrics — including per-phase `backup_phase_duration_seconds` —
to VictoriaMetrics. Telemetry failures never change the script's own exit
status.

## imperishable-night

NixOS's `services.restic.backups.daily` runs as the
`restic-backups-daily` service at 03:00 UTC, and catches up on boot if the
host was down then. It backs up `/var/lib`, excluding podman's
`/var/lib/containers`. Then it runs `unlock` and `forget --prune` with the
same retention as lotus-land-story, limited to `--host=imperishable-night`
so the policy never touches lotus-land-story's snapshots. Backup and prune
both pass `--retry-lock=30m`, so a run waits out the other host's prune
instead of failing on its exclusive lock.

The unit pings its own healthchecks.io check: `/start` before the backup,
then success or `/fail` from `$SERVICE_RESULT` after it stops. It then
pushes `backup_success`, `backup_duration_seconds`, and
`backup_completed_timestamp` to VictoriaMetrics with
`host="imperishable-night"`, but no per-phase durations, since the module
runs its commands without breadcrumbs. The personal dashboard's backup
panels show one series per host. The password and check UUID come from
`imperishable-night/secrets.sops.yml`.

## Repository

`sftp:restic@legacy-of-lunatic-kingdom:/mnt/data/restic`, defined as a play
var in `lotus-land-story/backup.yml` and templated into the script, and in
imperishable-night's configuration. It lives under a `restic` system user,
reachable by SSH keys for lotus-land-story (the backup), imperishable-night
(its SSH host key), and 1password (manual restores). The password is stored
in `host_vars/lotus-land-story.sops.yml`, with a copy in
`imperishable-night/secrets.sops.yml`.

## What the playbooks handle

- The backup play trusts lolk's host key by reading it over Ansible and
  writing it to known_hosts; the script's sftp connection fails closed on an
  unknown host key.
- lolk's playbook (`legacy-of-lunatic-kingdom/main.yml`) hosts the repository
  (user, keys, directory), so it has to be applied before the backup play can
  first reach `restic@lolk`.

## Verifying a run

```sh
ssh lotus-land-story sudo /etc/cron.daily/backup
ssh lotus-land-story journalctl -t backup
```

The journal shows the restic output and the phase breadcrumbs;
healthchecks.io should show the success ping for the same run.

On imperishable-night:

```sh
ssh imperishable-night sudo systemctl start restic-backups-daily
ssh imperishable-night journalctl -u restic-backups-daily
```
