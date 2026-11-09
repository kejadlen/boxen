# Direction

boxen configures a small fleet: Linodes for public and personal
services, a NAS at home for data, and a few single-purpose devices. This
document says where the fleet is heading and why. Each move has its own
plan, linked below; update this document when a goal or a plan changes.

## Goals

NixOS is the default for a host that's being set up or reinstalled
anyway. Its services run as podman containers through
`virtualisation.oci-containers`. imperishable-night started this way,
and legacy-of-lunatic-kingdom (lolk) moves when adding immich and
jellyfin makes the reinstall worth it. A host that works on Ansible
stays on Ansible until a reason to touch it comes along. The fleet is
too small for one configuration model to be worth forcing.

The fleet runs fewer things. A service nobody uses gets dropped rather
than migrated: monica, ramble-hard, dockhand, and gitea are gone, with
quire replacing gitea. What remains moves as-is, with
upgrades kept out of the move so that a failure has one cause.

Every host stays on a supported OS and takes updates. lotus-land-story's
bullseye went out of support with no clean upgrade path, which is what
started the move to NixOS. On NixOS, updating is bumping `flake.lock`
and deploying.

Backups are verified, not assumed. Each host backs up nightly with
restic to lolk, pings healthchecks.io, and pushes metrics to
VictoriaMetrics. See [backups](backup.md). The servers' backups don't
leave home, though: the restic repository and lolk's own data have no
offsite copy, so a fire at home loses every server backup at once. An
offsite copy is important but not urgent.

A failure that matters alerts someone instead of only showing up on a
dashboard. Today only healthchecks.io notifies. Grafana's one alert
rule, "Disk space", has failed to evaluate since July 2025 because its
datasource no longer exists. On 2026-10-18, mountain-of-faith's USB drive
dropped off the bus, and minio ran without it for two weeks before anyone
noticed. How alerts are defined and where they're sent is still open.

Most services that aren't about the home stay up when home is down, so
they run on a Linode. That includes monitoring, which needs to keep
running when the hosts it watches go down. Home runs what's about the
home, such as Home Assistant, pihole, BirdNET-Pi, and syncthing, plus
the storage-heavy media that's planned for lolk. When a home service
needs a public site, the Linode's Caddy serves it and proxies to home
over the tailnet, as `birbs.chislan.family` does, so the home network
opens no ports.

Memory doesn't drive placement. All the containers together averaged
about 2.8 GB over October 2026, against imperishable-night's 8 GB and
lolk's 12 GB, of which lolk used 17%. One Linode is enough once
lotus-land-story retires.

Access goes through the tailnet. SSH is tailnet-only on NixOS hosts,
private sites are their own Tailscale nodes through caddy-tailscale, and
one Caddy root CA signs every host's internal certificates. Only public
sites open ports to the internet.

## Where each host is going

The following table lists each host and where it's headed:

| Host | Today | Heading |
|---|---|---|
| lotus-land-story | Linode, Debian bullseye, Docker, Ansible | Retires once its services [move to imperishable-night](imperishable-night/2026-10-16-migrating-from-lotus-land-story.md) |
| imperishable-night | Linode, NixOS | Takes over lotus-land-story's services, including observability |
| legacy-of-lunatic-kingdom | Home NAS, Debian trixie, Quadlet, Ansible | [Reinstalls with NixOS](legacy-of-lunatic-kingdom/2026-11-01-migrating-to-nixos.md), then takes over UPS monitoring and runs immich and jellyfin |
| mountain-of-faith | minio and UPS monitoring, Ansible | Hands UPS monitoring to lolk and stays on Ansible |
| hopeless-masquerade | Raspberry Pi running BirdNET-Pi, Ansible | Stays on Ansible |
| double-dealing-character | Brume 2 exit node, configured by hand | Stays hand-configured |

## Order of work

1. Move lotus-land-story's remaining services to imperishable-night.
2. Retire lotus-land-story.
3. Reinstall lolk with NixOS. Its configuration shares `modules/nixos/`
   with imperishable-night.
4. [Copy the restic repository offsite](legacy-of-lunatic-kingdom/2026-11-01-shrinking-and-offsiting-backups.md),
   along with lolk's own data, to Backblaze B2.
5. Move UPS monitoring, NUT and the UPS's USB cable, from
   mountain-of-faith to lolk.
6. Add immich and jellyfin to lolk, once their data has an offsite
   backup.
7. Add alerting.
