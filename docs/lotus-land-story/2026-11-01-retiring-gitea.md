# Retiring gitea

quire hosts the source for most repositories, and GitHub mirrors them
from quire. For those, gitea is only a second mirror. The rest still
live on gitea and need a new home first (see
[Repositories still on gitea](#repositories-still-on-gitea)). This plan
retires gitea, along with anubis and the Actions runner, instead of
moving them to imperishable-night with the rest of lotus-land-story's
services. quire moves to imperishable-night as planned in the
[migration plan](../imperishable-night/2026-10-16-migrating-from-lotus-land-story.md).

Nothing on gitea needs to survive except the source. Issues, wikis, and
releases are not exported. restic's snapshots of `/mnt/lotus-land-story/`
include gitea's data directory, so a copy remains until those snapshots
age out.

## Confirm that quire has everything

Before gitea stops, follow these steps:

1. List alpha's repositories on gitea, including private ones, and check
   that quire has each one with the same branches and tags.
2. For each repository with a `.gitea/workflows/` directory, port the
   workflows to `.github/workflows/` so that they run on the GitHub
   mirror.
3. Remove the `:gitea-mirror` entry from each repository's
   `.quire/config.fnl`, so that quire stops pushing to gitea.

### Repositories that were on both

Six repositories were on both gitea and quire: boxen, frork, ketchup,
low-quality-transcripts, ramekin, and ranger. On 2026-11-03, they were
deleted from gitea after a fetch from each showed that gitea had nothing
quire lacked. The exceptions were six ranger release tags whose commits
are on quire, which weren't worth keeping. Their `.quire/config.fnl`
files no longer mirror to gitea.

### Repositories still on gitea

The following 17 repositories are on gitea and not on quire. Each one
moves to quire, stays only on GitHub, or is dropped:

| Repository | Last updated on gitea | Notes |
|---|---|---|
| dotfiles | 2026-11-03 | Local clone pushes to gitea as `origin` |
| rank-king | 2026-10-29 | Local clone pushes to gitea as `origin` |
| notes | 2026-04-03 | The only private repository |
| serde-kdl2 | 2026-03-25 | |
| pinch | 2026-02-21 | |
| advent-of-code | 2025-12-10 | |
| junk-drawer | 2025-10-22 | |
| birbnet | 2025-08-21 | |
| vim-colors-paramount | 2025-05-03 | |
| homebrew-tap | 2025-02-22 | |
| alphadex | 2025-02-19 | |
| alpheus-v2 | 2025-02-19 | |
| crafting-interpreters | 2025-02-19 | |
| Kaleidoscope | 2025-02-19 | |
| minitest-thesis | 2025-02-19 | |
| prezto | 2025-02-19 | |
| qmk_userspace | 2025-02-19 | |

The 2025-02-19 repositories share a date that looks like an import, not
activity. A repository that moves to quire also switches its local
clones' `origin` from gitea to quire.

## Redirect git.kejadlen.dev

`git.kejadlen.dev/alpha/<path>` redirects permanently to
`quire.kejadlen.dev/<path>`. Any other path redirects to quire's root.
git follows a redirect on the first request of a clone or fetch, so old
remotes keep working over HTTPS as long as quire serves the same path.
Deep links into gitea's web UI, such as `/alpha/boxen/src/branch/main/...`,
only resolve if quire uses the same layout, which is unverified.

The site replaces gitea's in lotus-land-story's Caddyfile:

```caddy
git.kejadlen.dev {
	log

	handle_path /alpha/* {
		redir https://quire.kejadlen.dev{uri} permanent
	}

	redir https://quire.kejadlen.dev permanent
}
```

The redirect moves to imperishable-night with quire, and the `git` A
record in `dns.tf` moves with quire's record.

## Remove gitea's configuration

Deleting gitea removes the following pieces of configuration:

| Where | What |
|---|---|
| `lotus-land-story/gitea.yml` | The whole playbook: gitea, anubis, act_runner, the `git` user, and the `/usr/local/bin/gitea` SSH shim |
| `lotus-land-story/security.yml` | The gitea fail2ban filter and jail |
| `lotus-land-story/vector.yml` | The logrotate entry for `/var/log/gitea.log` |
| `lotus-land-story/templates/vector.yml` | The gitea branch of the docker remap, and the `gitea_ssh` and `gitea_log` transforms |
| `lotus-land-story/templates/Caddyfile` | The gitea site, which becomes the redirect above |
| `lotus-land-story/caddy.yml` | The `undefined-fantastic-object` IP lookup, which only fed gitea's webauth bypass |
| `lotus-land-story/templates/authelia_configuration.yml` | The `gitea` OIDC client |
| `lotus-land-story/templates/scrape.yml` | The `gitea` and `anubis` jobs |
| `host_vars/lotus-land-story.yml` | The `gitea`, `gitea_runner`, and `anubis` version pins |
| `host_vars/lotus-land-story.sops.yml` | The `gitea` secrets and `quire.gitea_mirror` |
| `lotus-land-story/quire.yml` | The `gitea_mirror` secret file and its config entry |
| `main.tf` | The `pihole_dns_record.domains` resource, whose only record is `git.kejadlen.dev` |
| `.quire/config.fnl` and `.gitea/` | boxen's gitea mirror and issue template |
| Grafana | The Gitea dashboard |

The pihole record existed so that the laptop reached gitea over the
tailnet, where the webauth bypass could match its address. Without the
bypass, `git.kejadlen.dev` needs no tailnet address. The pihole provider
stays, because its commented-out resources may come back.

## Tear down the host

Removing a playbook doesn't stop what it started. After deploying the
configuration changes, follow these steps on lotus-land-story:

1. Remove the `gitea`, `anubis`, and `gitea-runner` containers.
2. Delete `/etc/fail2ban/filter.d/gitea.local`,
   `/etc/fail2ban/jail.d/gitea.local`, and `/etc/logrotate.d/gitea-ssh`,
   then restart fail2ban.
3. Delete `/usr/local/bin/gitea` and the `git` user.
4. Deregister the runner, if gitea's admin UI is still reachable, or
   ignore it, since it disappears with gitea.

Leave `/mnt/lotus-land-story/gitea` in place until lotus-land-story
retires, as a faster rollback than restic.

## Move quire

quire follows the migration plan's [Move a service][move] steps, with
the following differences:

- quire mounts the Docker socket, and its sshd `ForceCommand` runs
  `docker exec`. On imperishable-night, both use podman's
  Docker-compatible socket and `podman exec`.
- The `Match User quire` block moves into `services.openssh`.
- quire has a tailnet site, `quire`, and a public site,
  `quire.kejadlen.dev`. Each one moves as the migration plan describes.
- quire-gitweb moves with quire, since it reads quire's repositories.
- `quire.github_mirror`, `quire.github_auth_header`, and
  `quire.sentry_dsn` move to `imperishable-night/secrets.sops.yml`.
- lotus-land-story allows public SSH "for gitea from work laptop," and
  quire takes pushes over that same port. imperishable-night's SSH is
  tailnet-only, so the work laptop switches to pushing over HTTPS to
  `quire.kejadlen.dev`, with credentials from a git credential helper.
  quire doesn't authenticate pushes on its public site yet, so it needs
  that feature before it moves.

[move]: ../imperishable-night/2026-10-16-migrating-from-lotus-land-story.md#move-a-service

## Order of work

1. Confirm that quire has every repository, and port any workflows to
   GitHub.
2. Remove the gitea mirror from each repository's quire config.
3. Replace the gitea site with the redirect, remove the rest of gitea's
   configuration, and deploy lotus-land-story and tofu.
4. Tear down gitea on lotus-land-story.
5. Add authenticated HTTPS pushes to quire, and switch the work laptop's
   remotes to HTTPS.
6. Move quire, the redirect, and both A records to imperishable-night.
