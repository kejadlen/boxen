#!/usr/bin/bash

set -euo pipefail

export RESTIC_REPOSITORY=sftp:restic@mountain-of-faith:/mnt/mountain-of-faith/restic
export RESTIC_PASSWORD={{ restic.password }}

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

report() {
  status=$?

  local end_time timestamp labels
  end_time=$(date +%s)
  timestamp=${end_time}000 # milliseconds
  labels="{job=\"backup\",host=\"${hostname}\"}"

  if [[ ${status} -eq 0 ]]; then
    ping_healthcheck
    push_metrics "backup_success${labels} 1 ${timestamp}
backup_duration_seconds${labels} $((end_time - start_time)) ${timestamp}
backup_completed_timestamp${labels} ${end_time} ${timestamp}"
  else
    ping_healthcheck /fail
    push_metrics "backup_success${labels} 0 ${timestamp}"
  fi
}
trap report EXIT

# Records that the script started, so a run that dies before the first restic
# call is distinguishable from one that never fired at all.
ping_healthcheck /start

restic --verbose backup \
  /mnt/lotus-land-story/ \
  --exclude=/mnt/lotus-land-story/docker

restic --verbose backup \
  --stdin-filename lotus-land-story.sql \
  --stdin-from-command \
  -- \
  sudo -iu postgres pg_dumpall

restic --verbose forget \
  --keep-within-daily 1m \
  --keep-within-weekly 1y \
  --keep-within-monthly 100y \
  --prune
