# SQLite backups under a live writer

imperishable-night's nightly backup dumps gotosocial's 2 GB SQLite
database before restic runs. The first run used the `sqlite3` CLI's
`.backup` command, carried over from lotus-land-story, and wrote 11 GB
to dump that 2 GB database. This evaluation compares `.backup` with
`VACUUM INTO`. The outcome is to dump with `VACUUM INTO` into a
temporary file and move it into place. [Backups](../backup.md) describes
the current job.

## What the first run cost

Before gotosocial moved, imperishable-night's `restic-backups-daily`
unit read at most 430 MB and wrote about 110 MB a night. The first run
with gotosocial, on 2026-11-12, read 11.8 GB and wrote 11 GB. restic
accounts for about 5 GB of the reads: it processed 6.2 GiB, against 1.3
GiB the night before, because every file under `/var/lib/gotosocial` was
new to it. Nothing else in the run writes gigabytes, so the dump wrote
about five times the size of the database.

## Why `.backup` copies more than once

`.backup` uses SQLite's [online backup API][backup-api]. The CLI copies
100 pages per step and loops with no pause between steps
(`src/shell.c.in` in SQLite 3.54.0's source). Between steps, the copy
holds no lock on the source, so gotosocial keeps writing. That design
has two costs:

- A write to the source from another connection restarts the copy at
  the first page on the next step. The longer the copy takes, the more
  writes land during it.
- Overwriting an existing copy is one transaction on the destination.
  The copy inherits WAL mode from gotosocial's database, so every page
  goes through the destination's WAL before reaching the database file,
  which doubles the writes.

[backup-api]: https://www.sqlite.org/c3ref/backup_finish.html

## Local test

A Python script reproduced both costs on the workstation with SQLite
3.53.3, the version in imperishable-night's nixpkgs. It built a 195 MB
WAL-mode database and backed it up with Python's `sqlite3` module, which
calls the same backup API, at 100 pages per step. In some runs, a second
process inserted a row at a fixed interval during the backup. The
following table shows the results:

| Run | Restarts | Pages copied | Destination WAL |
|---|---|---|---|
| New destination, no writer | 0 | 196 MB | None |
| Existing destination, no writer | 0 | 196 MB | 196 MB |
| Existing destination, a write every second | 0 | 196 MB | 393 MB |
| Existing destination, a write every 0.2 seconds | 2 | 455 MB | 590 MB |
| `VACUUM INTO` a new file, a write every 0.2 seconds | Not applicable | 195 MB | None |

The test didn't explain the 393 MB WAL in the third run, which had no
restarts. Each copy took under a second, faster than the host's disk
would allow.
A 2 GB copy takes about ten times as long, so gotosocial gets about ten
times as many chances to restart it.

## Comparison

The following table compares the two commands for a nightly dump:

| | `.backup` | `VACUUM INTO` |
|---|---|---|
| Live writer | Restarts on writes, and might never finish if writes are frequent enough | Reads one snapshot, so writes don't affect it |
| Nightly I/O | Twice the database per pass, times the number of passes | One read of the database and one write of a new file |
| Output | A page-for-page copy, free pages included, in WAL mode | A compacted copy in rollback-journal mode |
| CPU | Copies pages | Rebuilds the tables and indexes |
| Effect on gotosocial | None between steps | Holds a read snapshot for the whole copy, so gotosocial's WAL can't checkpoint past it until the copy finishes |
| Existing output file | Overwrites it in place | Refuses to write, so the job writes a temporary file and moves it over the old copy |
| Disk space | None beyond the copy | A second copy until the move |

## Outcome

The job dumps with `VACUUM INTO` because its cost is bounded, and the
test showed it unaffected by a writer. It writes to
`/var/lib/gotosocial/backup/sqlite.db.tmp`, removing any temporary file
a failed run left, and moves the result over `sqlite.db` only when the
dump succeeds.

One cost isn't measured: restic's deduplication across nights. `.backup`
keeps each page at the same offset, so a night's changes stay local.
`VACUUM INTO` lays the file out again, and interior B-tree pages store
child page numbers, so a small change can alter more of the file. restic
splits files by content rather than at fixed offsets, which limits the
effect. The `Added to the repository` line in
`journalctl -u restic-backups-daily` shows each night's new data. If it
stays near the size of the database rather than the size of a day's
changes, revisit this choice.
