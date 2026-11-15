# Public names for tailnet sites

imperishable-night's tailnet sites answer on bare MagicDNS names like
`https://books`, with certificates from Caddy's private root. Every
device that opens them has to trust that root. `contacts.chislan.family`
is the exception: it has a public name whose A record points at its
tailnet address, and Caddy gets a publicly trusted certificate for it
over DNS-01 with the account-wide DNSimple token. This evaluation
compares ways to give the people-facing sites the same kind of name. The
outcome is a self-hosted [acme-dns][acme-dns] on imperishable-night that
answers Let's Encrypt's DNS-01 challenges for a `*.chislan.family`
wildcard, so the DNSimple token leaves the host.

[acme-dns]: https://github.com/acme-dns/acme-dns

## Why move off bare names

The private root is the cost. Every phone, Mac, and Apple TV that opens a
site has to trust it, and a device that trusts it extends
[risk 5](../threat-model.md#5-a-root-ca-with-no-limits) to that device.
A publicly trusted certificate needs no root on the device.

## Options

The following table compares the ways to get publicly trusted
certificates for tailnet-only sites:

| Option | Certificate from | Secret on imperishable-night | Verdict |
|---|---|---|---|
| `ts.net` names | Tailscale | None beyond the auth key | Ruled out: the names are long and tied to the tailnet |
| `chislan.family` with the DNSimple token | Let's Encrypt over DNS-01 | The account-wide DNSimple token | Ruled out: every site would depend on the token that [risk 4](../threat-model.md#4-a-linodes-secrets-reach-past-it) wants gone |
| `chislan.family` with `_acme-challenge` delegated to another provider | Let's Encrypt over DNS-01 | A token limited to one zone at the new provider | Ruled out: it adds a DNS provider |
| Upgrading DNSimple to limit the token to `chislan.family` | Let's Encrypt over DNS-01 | A token that still reaches `chislan.family`'s MX records | Ruled out: it costs a plan upgrade, and the token still reaches past certificates |
| `chislan.family` with self-hosted acme-dns | Let's Encrypt over DNS-01 | acme-dns credentials that can set one TXT record | Chosen |

Moving more sites onto the existing DNSimple token adds no new reach,
since the token is already on the host for contacts. It does make the
token harder to remove later, because every site would need it.

## How acme-dns works

acme-dns is an authoritative DNS server for one delegated subdomain,
with an HTTP API for setting TXT records. Registering through
`POST /register` returns a username, a password, and a `fulldomain` like
`<uuid>.acme.chislan.family`. Those credentials can set the TXT record
for that one name and nothing else.

A name validates through acme-dns when its `_acme-challenge` record is a
CNAME to the `fulldomain`. Let's Encrypt follows the CNAME and asks
acme-dns for the TXT record, and Caddy sets that record through the
[`caddy-dns/acmedns`][caddy-acmedns] module. DNSimple serves only the
fixed records, which tofu manages from the workstation.

One registration covers a wildcard. `*.chislan.family` and
`chislan.family` both validate at `_acme-challenge.chislan.family`, so
one CNAME and one set of credentials cover every site. A wildcard also
keeps the site names out of Certificate Transparency logs.

[caddy-acmedns]: https://github.com/caddy-dns/acmedns

## Design on imperishable-night

The following pieces make up the setup:

- An acme-dns container answers DNS on UDP and TCP 53 on
  imperishable-night's public IP. Binding to that address keeps it clear
  of any resolver on localhost.
- The API listens only on a podman network shared with Caddy, with
  `tls = "none"`, since nothing outside the host calls it.
  `disable_registration = true` turns registration off once Caddy's
  account exists, and the account's `allowfrom` limits updates to
  Caddy's subnet.
- Caddy reads the credentials from a sops-managed file in the format the
  module documents, replacing `caddy/dnsimple_token`.
- acme-dns stores accounts in SQLite under `/var/lib/acme-dns`. Losing
  the database costs a new registration and a new CNAME target, so it
  doesn't need a backup.
- The `caddy-kejadlen` image gains the `caddy-dns/acmedns` module.

The following records in `dns.tf` delegate the subdomain and point the
challenge at it:

| Name | Type | Value |
|---|---|---|
| `acme-ns.chislan.family` | A | imperishable-night's public IPv4 address |
| `acme.chislan.family` | NS | `acme-ns.chislan.family` |
| `_acme-challenge.chislan.family` | CNAME | The registration's `fulldomain` |

Putting the nameserver's address outside the delegated subdomain avoids
needing glue records inside it.

Both firewalls open 53: `linode_firewall.imperishable_night` in
`main.tf`, and `networking.firewall` in
`imperishable-night/configuration.nix`. lotus-land-story's firewall
doesn't change.

## Which sites move

The people-facing sites move to `<name>.chislan.family`: `books`,
`docs`, `grafana`, `homebox`, `irc`, `ketchup`, `quire`, and `rss`, plus
contacts, which switches from the DNSimple token to acme-dns. Each needs
an A record in `dns.tf` that follows its tsnet node's address, the way
`contacts` follows `data.tailscale_device.pro_tacts`. contacts already
shows that public names resolving to tailnet addresses work through
pi-hole.

`logs`, `metrics`, and `traces` keep their bare names and the private
root. Only machines call them: the OTEL exporters, Vector, and the
backup job's metrics push all trust `caddy-root.crt`. The root stays,
but phones and the Mac no longer need to trust it once their sites have
moved, which narrows risk 5 to the NixOS hosts.

Moving a site touches more than the Caddyfile. These settings name a
site by its bare URL:

- Grafana's `root_url` in `imperishable-night/observability.nix`.
- miniflux's `BASE_URL` and paperless-ngx's `PAPERLESS_URL` in
  `imperishable-night/containers.nix`.
- The blackbox probes and the miniflux scrape in
  `imperishable-night/scrape.yml`.

## Costs

acme-dns is a public authoritative DNS server, which is new attack
surface on a Linode. It answers only for `acme.chislan.family`, but it's
a Go service on port 53 that anyone can reach.

If acme-dns is down when a renewal comes due, Caddy keeps retrying.
Caddy renews with a third of a certificate's lifetime left, so an outage
has weeks before anything expires.

A compromised acme-dns, or a leak of its credentials, can get
certificates for `*.chislan.family`. That's far less than the DNSimple
token reaches today. A foothold on the host already holds the sites'
private keys.

## Open questions

- What does acme-dns v2.0's breaking change cover? Read the CHANGELOG
  before writing its config.
- How does Caddy 2.11 choose the wildcard for each site block? Check
  whether it needs a `*.chislan.family` site or the `auto_https
  prefer_wildcard` global option.
- `docs.chislan.family` already points at lotus-land-story, and no
  Caddyfile in the repository serves it. Confirm it's unused before
  repointing it.
- Should the bare names keep working during the move, so bookmarks and
  synced clients carry over? That needs a second site block on the same
  tsnet node.
