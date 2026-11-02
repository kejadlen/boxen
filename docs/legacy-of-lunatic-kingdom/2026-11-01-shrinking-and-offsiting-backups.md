# Shrinking the backups and copying them offsite

The restic repository on legacy-of-lunatic-kingdom (lolk) is the only
long-term copy of the backups, and lolk's own data has no backup at all.
A fire or a failed array at home loses both. This plan shrinks the
repository first, so that the offsite copy is smaller, and then copies
the repository and lolk's own data offsite.

## What's in the repository

On 2026-11-01, the repository held 180 GiB, or 371 GiB before
compression, for about 10.5 GiB of live data: 9.3 GiB from
lotus-land-story's files, 84 MiB from its `pg_dumpall`, and 1.2 GiB from
imperishable-night. Dedup only helps with data that stays put. Between
two consecutive daily snapshots, restic added 1.8 GiB and removed
2.0 GiB, so about a fifth of the live set turns over every day. The
retention policy keeps monthly snapshots forever, so every version stays.

The following directories account for the churn:

| Directory | Live size | Files changed in a day |
|---|---|---|
| `victoria-logs` | 120 MiB | 11,665 |
| `gotosocial` | 5.4 GiB | 2,503 |
| `victoria-traces` | 3 MiB | 976 |
| `victoria-metrics` | 810 MiB | 492 |

A directory can't add more in a day than its live size, so most of the
1.8 GiB comes from gotosocial and VictoriaMetrics. gotosocial keeps media
under `data/<account ID>/`, with one directory per account, remote
accounts included. Apart from the 2.1 GiB `sqlite.db`, its data is mostly
cached media from other servers, which gotosocial fetches again on demand.

## Shrink the backup

Each change below applies to lotus-land-story's backup script now, and
to imperishable-night's `services.restic.backups.daily` when the service
moves there.

Exclude `victoria-logs` and `victoria-traces`. They hold telemetry, and
losing them costs only old log lines and traces.

Back up VictoriaMetrics with `vmbackup` instead of copying its live data
directory, which isn't guaranteed to be consistent. A new phase runs the
`vmbackup` image at the same version as VictoriaMetrics, with
`-snapshot.createURL=http://victoria-metrics:8428/snapshot/create`,
`-storageDataPath` mounted from `/mnt/lotus-land-story/victoria-metrics/data`,
and `-dst=fs:///backup` mounted from `/mnt/lotus-land-story/victoria-metrics/backup`.
`vmbackup` mirrors VictoriaMetrics' parts, so this fixes consistency but
not churn. To keep the churn from piling up, the files phase excludes
all of `victoria-metrics/`, and a separate restic snapshot of `backup/`,
tagged `victoria-metrics`, keeps 7 days with `--keep-within-daily 7d`.
Metrics history only needs the latest consistent copy to survive a
rebuild.

restic's `forget` applies one policy to every snapshot it considers, so
each policy needs its own `forget` run, filtered by tag. Every other
snapshot gets the tag `long-term`, and the existing snapshots get it with
`restic tag --add long-term` before the new policies first run. When
VictoriaMetrics moves to imperishable-night, it becomes a second
`services.restic.backups` job with its own `pruneOpts`.

Back up gotosocial's database with `sqlite3 sqlite.db '.backup ...'`
before the files phase, as pro-tacts' dump does, and exclude the live
`sqlite.db` and its `-wal` and `-shm` files. gotosocial runs SQLite in
WAL mode, so a file-level copy can miss committed transactions.

Exclude gotosocial's remote media. Exclude `gotosocial/data/*`, then
re-include the database dump and the directories of the two local
accounts, which `select id, username from accounts where domain is null`
lists.

Change the retention for `long-term` snapshots on both hosts to the
following:

```sh
--keep-within-daily 1m
--keep-within-weekly 3m
--keep-within-monthly 2y
--keep-within-yearly 100y
```

## Reclaim the existing history

The exclusions only shrink new snapshots. To reclaim the space the old
snapshots hold, run `restic rewrite --forget` with the same exclusions,
then both `forget` runs with the new retention, and then `prune`.
Excluding all of `victoria-metrics/` from the old snapshots drops their
copies of its live data, which the tagged snapshots replace. The rewrite
leaves the old copies of `sqlite.db` in place, since they're the only
history of gotosocial's database.

Run these commands from the workstation, outside both hosts' backup
windows. `prune` takes the repository's exclusive lock for as long as it
runs, and on 180 GiB that may be hours. Run `restic check` afterward.

## Copy offsite

The offsite copy needs to hold the repository after pruning, plus
whatever of lolk's own data needs a backup. lolk's `/mnt/data` holds
480 GB, of which the repository is about 193 GB, which leaves about
287 GB of lolk's own data.

Whatever the target, the copy should meet the following requirements:

- It's append-only from lolk, so that a compromised or broken host can
  add snapshots but not delete them. Pruning uses a separate credential
  that lives on the workstation.
- It's verified on a schedule with `restic check --read-data-subset`, so
  that a bad copy shows up before a restore needs it.
- It reports to healthchecks.io like the nightly backups.

There are two ways to fill it. `restic copy` copies snapshots into a
second repository and verifies them as it goes. If that repository is
initialized with `--copy-chunker-params`, dedup carries over. Replicating
the repository directory with rclone is simpler, but it copies any
corruption along with everything else. lolk's own data is a second
restic source that backs up straight to the offsite target.

The following targets are candidates:

| Target | Fit |
|---|---|
| Backblaze B2 | restic supports it natively; app keys without delete permission, plus object lock, make it append-only |
| Cloudflare R2 | S3-compatible, with no egress fees, which makes restores and `--read-data-subset` checks cheap |
| Linode Object Storage | Already on the account and in tofu, but it's the same provider as the hosts |
| Hetzner Storage Box | sftp that restic uses directly; append-only is harder |
| rsync.net | sftp with ZFS snapshots on the provider's side, which keeps history even if the host deletes it |
| A box at another location | A small machine with a disk on the tailnet; no monthly bill, but one more host to keep running |

Pricing isn't compared here, because it changes. Compare it when you
choose.

## Open questions

- How much of lolk's 287 GB needs an offsite copy? syncthing replicates
  to its peers, but deletions replicate too, so syncthing isn't a backup.
  Re-downloadable data doesn't need one.
- Which target?
- Does the restic version on each host support `!` re-include patterns
  in excludes? lotus-land-story runs `restic self-update` in its backup
  play, and imperishable-night takes restic from nixpkgs.

## Order of work

1. Tag the existing snapshots `long-term`.
2. Change lotus-land-story's backup script: the exclusions, the tags,
   the `vmbackup` and gotosocial phases, and both retention policies.
3. Change imperishable-night's tag and retention to match.
4. Rewrite, forget, prune, and check the repository from the
   workstation.
5. Choose an offsite target, and decide what of lolk's own data it backs
   up.
6. Set up the offsite copy and its checks.
7. Update [backups](../backup.md).
