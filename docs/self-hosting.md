# Self-hosting

This document explains the pattern behind which services the fleet
runs, which it rents, and which it has dropped. It's meant for weighing
a new service, or a replacement for an old one. Where a service runs
and how it's reached are in [direction](direction.md).

## Self-host the data, rent the plumbing

The fleet self-hosts the services that hold personal data:

- paperless-ngx for documents
- calibre-web for books
- homebox for household inventory
- miniflux for feeds
- pro-tacts for contacts
- quire for git repositories
- gotosocial for the fediverse
- soju for IRC
- immich and jellyfin for photos and media, once they land on lolk

The commodity infrastructure that those services lean on is rented.
Fastmail holds the mailbox, smtp2go relays outgoing mail, DNSimple
serves DNS, healthchecks.io notices missed backups, Tailscale
coordinates the tailnet, and GitHub hosts container images and quire's
mirrors. Backblaze B2 is the planned offsite copy of the backups.

Each of these is hard to run well alone. Mail delivery needs an IP
reputation, DNS needs to stay up when the fleet doesn't, and a
dead-man's switch can't run on the hosts it watches. The mailbox is
personal data too, but it's the case where running the service well
costs more than keeping the data in-house is worth.

## Write a small tool before running a big suite

When the off-the-shelf option is heavier than the need, the fleet runs a
purpose-built tool instead. ketchup, pro-tacts, and quire are written
for this fleet, and quire replaced gitea. A small tool does only what's
used, fits the fleet's sign-in and tracing conventions from the start,
and has no features to patch that nobody uses.

## Prefer the small option in a category

When the fleet does adopt existing software, it picks the lightweight
option in the category: gotosocial for the fediverse, miniflux for
feeds, soju for IRC, and VictoriaMetrics, VictoriaLogs, and
VictoriaTraces for observability. Each ships as a single binary, so
there are fewer moving parts to configure, update, and monitor.

## Run fewer things

A service nobody uses is dropped rather than migrated or upgraded.
monica, ramble-hard, dockhand, gitea, and minio are gone. Every service
costs updates, backups, monitoring, and threat-model entries, so it has
to earn that cost by being used.

## Fit the access model

A service is easiest to run when it fits how the fleet already
authenticates. Most private sites trust Caddy's `tailscale_auth`, which
passes the Tailscale user as a header, so paperless-ngx, calibre-web,
ketchup, quire, miniflux, Grafana, and pro-tacts have no login of their
own. Authelia covers what the tailnet can't, as the OpenID Connect
provider for Tailscale sign-in and gotosocial. A candidate that supports
a trusted login header or OpenID Connect slots in. One that insists on
its own accounts is a cost to weigh.

## Grant each service only what it uses

A service gets the narrowest access that lets it work. Each app shares a
podman network only with Caddy, redis has no network at all, and
PostgreSQL roles reach only their own database. On the tailnet,
hopeless-masquerade runs a third-party installer, so `tag:birdnet` lets
it reach only VictoriaLogs and pi-hole. The same rule applies to
credentials that a service holds. If an integration would need access
to more than its own data, such as a token for a whole mailbox, the
integration should change shape so it doesn't need that access.

## Weighing a new service

A new service fits when it holds data worth keeping, is the smallest
option that covers the need, fits the existing sign-in, and can work
with access to only its own data. If it fails one of these, that isn't
disqualifying, but it's the cost to weigh against the reason for
running it.
