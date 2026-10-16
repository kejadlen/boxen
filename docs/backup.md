# Backups

A daily cron script backs lotus-land-story up with restic into a repository
on legacy-of-lunatic-kingdom. That repository is the only copy: losing lolk
loses the backups along with it.

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

## Repository

`sftp:restic@legacy-of-lunatic-kingdom:/mnt/data/restic`, defined as a play
var in `lotus-land-story/backup.yml` and templated into the script. It lives
under a `restic` system user, reachable by SSH keys for lotus-land-story
(the backup) and 1password (manual restores). The password is stored in
`host_vars/lotus-land-story.sops.yml`.

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
