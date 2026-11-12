# Migrating legacy-of-lunatic-kingdom to NixOS

The fleet is converging on NixOS. imperishable-night runs NixOS from a
flake, lotus-land-story retires as its services move there, and
legacy-of-lunatic-kingdom (lolk) is the last host configured by Ansible.
This plan reinstalls lolk with NixOS so that every host shares one
configuration model and one container convention.

There is no deadline. lolk runs Debian trixie, which is still supported,
so the move can wait until it's convenient. Two things make it worth
doing before lolk grows:

- immich and jellyfin are planned for lolk. Defining them in Nix from
  the start avoids writing Quadlet units that a later move would
  rewrite.
- lolk runs containers as Quadlet units, while imperishable-night uses
  `virtualisation.oci-containers`. One convention means one way to
  define, deploy, and debug a container.

Upgrading services or replacing containers with native NixOS modules is
out of scope, as it was for
[imperishable-night](../imperishable-night/2026-10-16-migrating-from-lotus-land-story.md).

## Protect the backups first

The restic repository under `/mnt/data/restic` is the only long-term
copy of the backups (see [backups](../backup.md)). Linode's backups go
back about two weeks and skip lotus-land-story's volume. A reinstall
that touches the wrong disk loses the restic history, so copy the 25 GiB
repository off lolk before installing.

The copy goes in `/mnt/mountain-of-faith/restic-copy` on
mountain-of-faith, which has plenty of room and once held the restic
repository itself. Push the repository from lolk over the tailnet with
`sudo rsync -a /mnt/data/restic/ mountain-of-faith:/mnt/mountain-of-faith/restic-copy/`.
An rsync copy is byte-identical, so a restore can point restic straight
at it, and an interrupted transfer resumes where it stopped. Then run
`restic check --read-data` from the workstation against
`sftp:mountain-of-faith:/mnt/mountain-of-faith/restic-copy`.

Delete the copy once lolk is verified on NixOS.

## Keep what identifies the host

Clients pin parts of lolk's identity, so carry these across the
reinstall instead of regenerating them:

- The SSH host keys in `/etc/ssh/`. imperishable-night pins lolk's
  ed25519 key in `programs.ssh.knownHosts`, and lotus-land-story's
  backup play writes it to known_hosts. Keeping the keys also keeps the
  age key that sops-nix would derive from them. nixos-anywhere's
  `--extra-files` can install them, the same way imperishable-night's
  install stages its Tailscale auth key.
- Syncthing's certificate and key under
  `/home/syncthing/.local/state/syncthing/`. Syncthing derives the
  device ID from them, and every peer knows lolk by that ID. Carry the
  whole directory to `/var/lib/syncthing/.config/syncthing/`, owned by
  `syncthing`, since its `config.xml` also holds the folders, devices,
  GUI credentials, and disk-free thresholds that the NixOS configuration
  leaves undeclared.
- Caddy's data directory, `/mnt/data/caddy/data`, which holds each
  tailnet site's node state. It's on the array, so it survives if the
  array does.

lolk's Caddy has its own local CA today. On NixOS it switches to the
shared root that imperishable-night deploys, so devices trust one root
for every host. It's deployed the same way: `caddy-root.crt` from the
repository and the root's key from lolk's sops secrets, wired into the
Caddyfile's `pki` block.

Tailscale can either keep `/var/lib/tailscale` or register fresh with a
single-use key, as imperishable-night did.

## Leave the array alone

lolk's three 2 TB NVMe drives form a RAID5 array, `/dev/md0`, that holds
`/mnt/data` (3.6 TB, 261 GB used). The NixOS configuration assembles the
existing array with `boot.swraid` and mounts it with `fileSystems`;
disko must never list the array's member devices.

The OS lives entirely on the 58 GB eMMC, `/dev/mmcblk0`: `/boot/efi` on
`p1`, `/boot` on `p2`, and an LVM volume group on `p3` with a 53 GB root
and a 3 GB swap volume. The NVMe drives are whole-disk array members
with no partitions. disko can therefore take the whole eMMC and never
touch the NVMe drives.

## Map each service

Each piece of lolk's Ansible configuration has a NixOS counterpart:

| Today | On NixOS |
|---|---|
| Caddy as a Quadlet unit (`caddy.yml`) | An `oci-containers` container, as on imperishable-night, keeping the 1 GB memory cap and `:2019` metrics port |
| syncthing from the Debian package | `services.syncthing`, with its data under `/mnt/data/syncthing` |
| restic's sftp-only user (`main.yml`) | `users.users.restic` and a `Match User restic` block in `services.openssh` |
| node-exporter with the systemd and apt collectors | `services.prometheus.exporters.node`; the apt collector goes away with apt |
| journal-upload to `lotus-land-story:9428` | `services.journald.upload` to `https://logs`, the tailnet site in front of VictoriaLogs, so the URL survives the observability stack moving |
| unattended-upgrades | Nothing. Updates come from bumping `flake.lock` and deploying, as on imperishable-night |
| Tailscale from the Debian package | `services.tailscale`, as on imperishable-night |
| `secure.yml`'s SSH and sudo settings | The same settings imperishable-night uses |
| The dhcpcd `nohook resolv.conf` fix | Nothing, if imperishable-night's networking setup carries over |

## Share configuration between hosts

imperishable-night's flake lives in `imperishable-night/`. With a second
NixOS host, the shared pieces (Tailscale, SSH and users, node-exporter,
and the Caddy container) can move into a module that both configurations
import. Extract them when lolk's configuration is written, not before,
so the module holds only what the two hosts actually share.

Each host keeps its own flake and lock, and the shared module lives in
`modules/nixos/`. Merging the hosts into one fleet flake with a single
lock is still an open question. Before a third NixOS host arrives, weigh
one bump updating the whole fleet against updating hosts independently.
The same review covers deployment: multi-host tools such as colmena and
deploy-rs, against the per-host `nixos-rebuild` recipes in the justfile.

## Order of work

1. Write lolk's NixOS configuration and confirm that it evaluates.
2. Copy the restic repository to mountain-of-faith, and check the copy.
3. Save the SSH host keys and Syncthing's state, which live on the root
   filesystem.
4. Install with nixos-anywhere over the LAN, with the host keys staged
   through `--extra-files`. lolk is physical hardware at home, so keep a
   keyboard and monitor nearby in case it doesn't boot.
5. Verify that `/mnt/data` is mounted, that imperishable-night's nightly
   restic run reaches the repository, that Syncthing peers reconnect,
   and that Caddy's sites come up.
6. Delete `legacy-of-lunatic-kingdom/main.yml`, `caddy.yml`, and their
   templates, and update
   [legacy-of-lunatic-kingdom](../legacy-of-lunatic-kingdom.md).
7. Delete the copy on mountain-of-faith.

immich and jellyfin come after the move, defined in Nix.
