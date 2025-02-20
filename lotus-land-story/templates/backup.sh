#!/usr/bin/bash

set -eux pipefail

RESTIC_REPOSITORY=sftp:restic@on-fire-within:/mnt/mushu/restic
RESTIC_PASSWORD={{ restic.password }}

restic --verbose backup /mnt/lotus-land-story/
restic --verbose backup --stdin-filename lotus-land-story.sql --stdin-from-command -- sudo -iu postgres pg_dumpall
