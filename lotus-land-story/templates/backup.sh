#!/usr/bin/bash

set -eu pipefail

export RESTIC_REPOSITORY=sftp:restic@mountain-of-faith:/mnt/mountain-of-faith/restic
export RESTIC_PASSWORD={{ restic.password }}

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
