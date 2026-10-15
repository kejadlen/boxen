# Backups

A daily cron script backs lotus-land-story up with restic into a primary
repository on mountain-of-faith, then mirrors every snapshot into a secondary
repository on legacy-of-lunatic-kingdom. Losing either machine loses at most
one day of backups.

## The daily run

`/etc/cron.daily/backup` on lotus-land-story (templated from
`lotus-land-story/templates/backup.sh`, owned by the play in
`lotus-land-story/backup.yml`) runs as root. cron has no MTA, so the script
sends its own output to the journal with the `backup` tag. It sets
`GOGC=20` so restic trades CPU for memory, since lotus-land-story has little
headroom and the OOM killer has taken restic mid-backup. Each run:

1. Pings healthchecks.io `/start`, distinguishing a run that died early from
   one that never fired.
2. Removes stale locks from the primary, so a run killed mid-flight (for
   example, by the OOM killer) doesn't block every later prune. The
   secondary gets the same treatment just before the copy, so a down lolk
   can't stop the primary backup.
3. Backs up `/mnt/lotus-land-story/`, excluding `docker/`.
4. Backs up `pg_dumpall` output via stdin as `lotus-land-story.sql`.
5. Runs `forget --prune` against the primary with retention of daily for one
   month, weekly for one year, monthly forever.
6. Mirrors every snapshot onto the secondary with
   `restic copy --from-repo <primary>`.

An exit trap pings healthchecks.io with success or failure and pushes
`backup_*` metrics to VictoriaMetrics. Telemetry failures never change the
script's own exit status, but the copy in step 6 does count toward it: a
broken mirror fails the run.

## Repositories

- Primary: `sftp:restic@mountain-of-faith:/mnt/mountain-of-faith/restic`
- Secondary: `sftp:restic@legacy-of-lunatic-kingdom:/mnt/data/restic`

Both live under a `restic` system user on the host, reachable by SSH keys for
lotus-land-story (the backup) and 1password (manual restores). The
repositories share one password, stored in `host_vars/lotus-land-story.sops.yml`.

Restic resolves the source repository's password separately from
`RESTIC_PASSWORD`, so the script exports `RESTIC_FROM_PASSWORD` for the copy.
The repository URLs are defined once as play vars in `lotus-land-story/backup.yml`
and templated into the script.

## What the playbooks handle

- The backup play trusts lolk's host key by reading it over Ansible and
  writing it to known_hosts; the script's sftp connection fails closed on an
  unknown host key.
- The play probes the secondary with `restic cat config` and, if missing,
  initializes it with `init --from-repo <primary> --copy-chunker-params`.
  Copy requires an existing destination, and matching chunker parameters let
  the mirror deduplicate against the primary instead of storing a second copy
  of every pack file.
- lolk's playbook (`legacy-of-lunatic-kingdom/main.yml`) hosts the repository
  (user, keys, directory), so it has to be applied before the backup play can
  first reach `restic@lolk`.

## The secondary is append-only

`forget --prune` runs against the primary only, so the secondary accumulates
every snapshot since the mirror started. If the NAS ever becomes the primary,
drop the copy step from `lotus-land-story/templates/backup.sh`, point
`RESTIC_REPOSITORY` at the NAS repository, and run a one-time
`forget --prune` there with the same retention flags.

## Verifying a run

```sh
ssh lotus-land-story sudo /etc/cron.daily/backup
ssh lotus-land-story journalctl -t backup
```

The journal shows the restic output including the copy; healthchecks.io
should show the success ping for the same run.
