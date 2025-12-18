#!/usr/bin/bash

set -eu pipefail

export RESTIC_REPOSITORY=sftp:restic@mountain-of-faith:/mnt/mountain-of-faith/restic
export RESTIC_PASSWORD={{ restic.password }}

# Capture start time
start_time=$(date +%s)

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

curl \
  --fail \
  --silent \
  --show-error \
  --max-time 10 \
  --retry 5 \
  --output /dev/null \
  https://hc-ping.com/{{ healthchecks_io.backup_sh }}

end_time=$(date +%s)
duration=$((end_time - start_time))
timestamp=${end_time}000  # milliseconds
hostname=$(hostname)
metrics="backup_duration_seconds{job=\"backup\",host=\"${hostname}\"} ${duration} ${timestamp}
backup_completed_timestamp{job=\"backup\",host=\"${hostname}\"} ${end_time} ${timestamp}"

# TODO Add the root cert to the system so this doesn't need --insecure
curl \
  --insecure \
  --fail \
  --silent \
  --show-error \
  --max-time 10 \
  --retry 3 \
  --data-binary "${metrics}" \
  https://metrics/api/v1/import/prometheus
