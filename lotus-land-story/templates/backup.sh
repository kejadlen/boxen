#!/usr/bin/bash

set -euo pipefail

readonly PRIMARY_REPOSITORY={{ primary_repository }}
readonly SECONDARY_REPOSITORY={{ secondary_repository }}

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

# A file-level copy of the running cluster isn't restorable; the postgres
# phase's pg_dumpall is. The glob also covers the postgresql-15 path the
# bookworm upgrade moves to.
phase files restic --verbose backup \
  /mnt/lotus-land-story/ \
  --exclude=/mnt/lotus-land-story/docker \
  --exclude='/mnt/lotus-land-story/postgresql*'

phase postgres restic --verbose backup \
  --stdin-filename lotus-land-story.sql \
  --stdin-from-command \
  -- \
  sudo -iu postgres pg_dumpall

phase forget restic --verbose forget \
  --keep-within-daily 1m \
  --keep-within-weekly 1y \
  --keep-within-monthly 100y \
  --prune

# Mirror onto mountain-of-faith while both are dual-write targets. Restic
# resolves the source repository's password separately from RESTIC_PASSWORD, so
# pass it explicitly; the repos share one.
export RESTIC_REPOSITORY=${SECONDARY_REPOSITORY}
export RESTIC_FROM_PASSWORD=${RESTIC_PASSWORD}
phase unlock-secondary restic unlock
phase mirror restic --verbose copy --from-repo "${PRIMARY_REPOSITORY}"
