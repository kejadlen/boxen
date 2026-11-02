#!/usr/bin/bash

set -euo pipefail

readonly PRIMARY_REPOSITORY={{ primary_repository }}

export RESTIC_REPOSITORY=${PRIMARY_REPOSITORY}
export RESTIC_PASSWORD={{ restic.password }}

# Trades CPU for memory; the host's headroom is thin enough to OOM restic.
export GOGC=20

readonly HEALTHCHECK=https://hc-ping.com/{{ healthchecks_io.backup_sh }}
readonly METRICS=https://metrics/api/v1/import/prometheus

# cron has no MTA to mail output to, so it discards it. Send it to the journal.
exec > >(logger --tag backup) 2>&1

# Telemetry must never change the backup's own exit status.
ping_healthcheck() {
  curl \
    --fail \
    --silent \
    --show-error \
    --max-time 10 \
    --retry 5 \
    --output /dev/null \
    "${HEALTHCHECK}${1-}" || true
}

push_metrics() {
  # TODO Add the root cert to the system so this doesn't need --insecure
  curl \
    --insecure \
    --fail \
    --silent \
    --show-error \
    --max-time 10 \
    --retry 3 \
    --data-binary "$1" \
    "${METRICS}" || true
}

start_time=$(date +%s)
hostname=$(hostname)

# Breadcrumbs for the journal: "> name" when a phase starts, "< name: Ns"
# when it finishes, so the last line shows where a slow or dead run sits.
# Durations ship as metrics from report().
phase_durations=""
phase() {
  local name=$1
  shift

  local start end
  start=$(date +%s)
  echo "> ${name}"
  "$@"
  end=$(date +%s)
  echo "< ${name}: $((end - start))s (total $((end - start_time))s)"
  phase_durations+="backup_phase_duration_seconds{job=\"backup\",host=\"${hostname}\",phase=\"${name}\"} $((end - start))
"
}

report() {
  status=$?

  local end_time timestamp labels
  end_time=$(date +%s)
  timestamp=${end_time}000 # milliseconds
  labels="{job=\"backup\",host=\"${hostname}\"}"

  if [[ ${status} -eq 0 ]]; then
    ping_healthcheck
    echo "backup finished: $((end_time - start_time))s"
    push_metrics "backup_success${labels} 1 ${timestamp}
backup_duration_seconds${labels} $((end_time - start_time)) ${timestamp}
backup_completed_timestamp${labels} ${end_time} ${timestamp}
${phase_durations}"
  else
    ping_healthcheck /fail
    echo "backup failed: status=${status}"
    push_metrics "backup_success${labels} 0 ${timestamp}
${phase_durations}"
  fi
}
trap report EXIT

# Records that the script started, so a run that dies before the first restic
# call is distinguishable from one that never fired at all.
ping_healthcheck /start

# A run killed mid-flight (e.g., by the OOM killer) leaves its lock behind,
# which blocks every later prune. unlock only removes stale locks.
phase unlock restic unlock

# Runs before the files phase so the dump it writes under /data is included
# in the file backup.
phase pro-tacts docker exec pro-tacts rake db:dump

# A file copy of a database in WAL mode can miss committed transactions;
# `.backup` goes through SQLite.
phase gotosocial sqlite3 /mnt/lotus-land-story/gotosocial/data/sqlite.db \
  '.backup /mnt/lotus-land-story/gotosocial/backup/sqlite.db'

# Every other account's directory is remote media that gotosocial re-fetches.
# Queried here rather than inside the exclude file's process substitution,
# where a failure would silently exclude the local accounts' media too.
gotosocial_local_ids=$(sqlite3 -readonly /mnt/lotus-land-story/gotosocial/backup/sqlite.db \
  'select id from accounts where domain is null')
if [[ -z ${gotosocial_local_ids} ]]; then
  echo "no local gotosocial accounts found"
  exit 1
fi

gotosocial_excludes() {
  echo '/mnt/lotus-land-story/gotosocial/data/*'
  while read -r id; do
    echo "!/mnt/lotus-land-story/gotosocial/data/${id}"
  done <<<"${gotosocial_local_ids}"
}

# A copy of the live data directory isn't guaranteed consistent; a snapshot is.
phase victoria-metrics-snapshot docker run --rm \
  --network lotus_land_story \
  --volume /mnt/lotus-land-story/victoria-metrics/data:/storage:ro \
  --volume /mnt/lotus-land-story/victoria-metrics/backup:/backup \
  quay.io/victoriametrics/vmbackup:{{ versions.victoria_metrics }} \
  -storageDataPath=/storage \
  -snapshot.createURL=http://victoria-metrics:8428/snapshot/create \
  -dst=fs:///backup

# A file-level copy of the running cluster isn't restorable; the postgres
# phase's pg_dumpall is. victoria-logs and victoria-traces are telemetry
# that churns too much to keep.
phase files restic --verbose backup \
  --tag long-term \
  /mnt/lotus-land-story/ \
  --exclude=/mnt/lotus-land-story/docker \
  --exclude='/mnt/lotus-land-story/postgresql*' \
  --exclude=/mnt/lotus-land-story/victoria-metrics \
  --exclude=/mnt/lotus-land-story/victoria-logs \
  --exclude=/mnt/lotus-land-story/victoria-traces \
  --exclude-file=<(gotosocial_excludes)

phase postgres restic --verbose backup \
  --tag long-term \
  --stdin-filename lotus-land-story.sql \
  --stdin-from-command \
  -- \
  sudo -iu postgres pg_dumpall

# vmbackup rewrites as many parts as VictoriaMetrics merges, so its snapshots
# get their own short retention.
phase victoria-metrics restic --verbose backup \
  --tag victoria-metrics \
  /mnt/lotus-land-story/victoria-metrics/backup

phase forget-victoria-metrics restic --verbose forget \
  --host lotus-land-story \
  --tag victoria-metrics \
  --keep-within-daily 7d

phase forget restic --verbose forget \
  --host lotus-land-story \
  --tag long-term \
  --keep-within-daily 1m \
  --keep-within-weekly 3m \
  --keep-within-monthly 2y \
  --keep-within-yearly 100y \
  --prune
