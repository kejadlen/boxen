# Fronting private sites with Tailscale Services

## Outcome

Dropped before any deploy, to keep short names like `https://ketchup`.
Serve terminates HTTPS only for a service's `ts.net` name, with a
certificate from Let's Encrypt, and "You cannot obtain an HTTPS URL to
go to a bare hostname" ([enabling HTTPS][https]). A tailnet can't use a
domain we own either: Serve's DNS names "are restricted to your
tailnet's domain name" ([Serve][serve]), and that name is either the
default `tail<hex>.ts.net` or a randomized `ts.net` name.

Any other certificate, from the shared root or for a domain we own,
means Caddy terminates TLS and Serve forwards raw TCP. Serve adds the
identity headers only to HTTP it terminates, so they would never reach
Caddy. Private sites stay on caddy-tailscale, which keeps Caddy's auth
key (risk 4), the shared root (risk 5), and grants per tag rather than
per site. Minting the key with `tag:site`, step 4 of the
[tailnet rollout](../tailnet.md#rollout), is the remaining fix for
risk 4.

Preparing the first experiment turned up two facts that matter to any
later attempt:

- A service must be defined in the admin console before a host can
  advertise it. The tofu Tailscale provider (0.29.3) has no resource for
  services.
- `tailscale serve set-config` takes a target's scheme as the front
  end's too, so `"tcp:443": "http://…"` serves plain HTTP on 443
  (`serveTypeFromConfString` in `cmd/tailscale/cli/serve_v2.go`,
  1.104.5). A unit per service that runs
  `tailscale serve --service=svc:<name> --https=443 http://…`, like
  Rex's, avoids that.

The plan as written follows.

## Plan

Every private site today is its own Tailscale node, registered by the
caddy-tailscale plugin inside the Caddy container with a reusable auth
key, and served with a certificate from the shared Caddy root. This plan
replaces those nodes with [Tailscale Services][services]: the host's own
tailscaled advertises each site as a named service and proxies it to
Caddy, which keeps routing to the containers as it does now.

The move pays off in four places:

- Caddy stops holding a Tailscale auth key. Today's key is reusable,
  preauthorized, and tagged `tag:server`, so a foothold on the host can
  enroll its own node (risk 4 in the [threat model](../threat-model.md)).
- Tailscale Serve terminates HTTPS with a certificate it provisions for
  the service's name, so the sites stop depending on the shared root CA
  (risk 5). Phones never need to trust the root for them.
- Grants can name a service, `svc:docs`, instead of a node tag, so the
  [tailnet policy](../tailnet.md) narrows per site rather than per host.
- caddy-tailscale goes away. The plugin is marked experimental, has no
  Services support ([issue 117][ct-117], [PR 136][ct-136]), and can't
  identify tagged source devices.

Services need a tagged host, so imperishable-night goes first and lolk
follows once its Caddy has sites. lotus-land-story's nodes are
user-owned and the host is retiring, so its sites move to Services only
as they move to imperishable-night. Public sites don't change: Caddy
keeps its public listeners, and Services has no Funnel integration yet.
Running each app as its own service host, with no Caddy in between, is
out of scope; Caddy is where routing and header mapping already live.

## Prove the headers first

Three apps on imperishable-night, quire, paperless-ngx, and ketchup, log
users in from a header that Caddy sets from the Tailscale identity. Serve
adds `Tailscale-User-Login` and `Tailscale-User-Name` to requests it
proxies, and strips any a client sends. The [Services page][services]
says only that layer 7 endpoints "work well when you need Tailscale to
inject authentication headers"; nothing states it for `svc:` endpoints
outright. So the first step is one service, `svc:ketchup`, in front of
ketchup while its caddy-tailscale node stays up, to record:

- which identity headers arrive, and their exact values (Serve gives the
  full login; `tailscale_login` in today's Caddyfile may be shorter);
- what `Host` header Serve passes to Caddy, which decides how site
  blocks match;
- whether the short name `ketchup` still resolves through MagicDNS, so
  bookmarks keep working;
- who issued the certificate.

Serve requires HTTPS certificates enabled on the tailnet, and a new
service host needs approval in the admin console unless
`autoApprovers.services` in the policy grants it to `tag:server`.

If the headers don't arrive, the fallback is to keep caddy-tailscale for
the identity sites and wait for [PR 136][ct-136], and to use Services
only for homebox and any other site that doesn't need identity.

## How the pieces fit

tailscaled holds one JSON file listing every service, built from Nix
and loaded by a oneshot unit that runs `tailscale serve set-config`.
Each service's endpoint is `tcp:443` with an `http://` target: Caddy's
loopback listener.

Caddy gains one plain-HTTP listener for the services, published on the
host's loopback only (`127.0.0.1:8080:8080`), with the site blocks
matching on the names Serve passes. `tls internal`, `bind tailscale/`,
and `tailscale_auth` go; `header_up Remote-User {header.Tailscale-User-Login}`
replaces the identity mapping. The listener must trust those headers
only from Serve. Inside the container, the host's connections arrive
from the `caddy` network's gateway, `10.89.0.1`, while the apps arrive
from their own networks, so a `remote_ip` matcher on the gateway gates
the identity sites and Caddy strips the headers from anything else.

The policy replaces the `tag:site` plan with grants whose destinations
are service names, and adds `autoApprovers.services` so a deploy that
adds a service doesn't wait on the console.

What goes away on imperishable-night:

| Today | After |
|---|---|
| `tailscale { auth_key }` in the Caddyfile and `TS_AUTHKEY` in `caddy.env` | Nothing. Caddy has no tailnet identity |
| `caddy/ts_authkey` in `secrets.sops.yml` and `tailscale_tailnet_key.imperishable_night_caddy` in `main.tf` | Deleted and revoked |
| One node per site in `/var/lib/caddy/data/tailscale` | Deleted, along with the nodes in the admin console |
| `caddy/ca_root_key` and the `pki` block | Kept until no site on the host uses `tls internal`, then deleted from the host |
| The `(ts)` snippet | A `(svc)` snippet: `log` and the `remote_ip` gate |

Rex's login server already runs this way, behind Serve on the host node
at 7297, and doesn't change.

## Map each site

Each private site on imperishable-night maps to one service:

| Site | Identity today | As a service |
|---|---|---|
| homebox | None | `svc:homebox`, no headers |
| docs | `tailscale_user` as `Remote-User` | `svc:docs`, `Remote-User` from `Tailscale-User-Login` |
| irc | `tailscale_auth` gate only | `svc:irc`, gated by the grant instead |
| ketchup | `tailscale_login` and `tailscale_user` as two headers | `svc:ketchup`, both from Serve's headers |
| quire | `tailscale_login` as `Remote-User` | `svc:quire`, `Remote-User` from `Tailscale-User-Login` |

Where an app got a short login today and Serve supplies the full one,
either the app's user records change to match or Caddy derives the short
form; the experiment decides which. lotus-land-story's sites take the
same shape as each one moves.

## Order of work

1. Confirm HTTPS certificates are enabled on the tailnet, and add
   `autoApprovers.services` for `svc:ketchup` to the policy in `main.tf`.
2. Add Caddy's loopback listener and the `svc:ketchup` service to
   imperishable-night, deploy, and record the findings above in this
   document.
3. If the headers arrive, move the remaining sites one deploy at a time,
   deleting each old node from the admin console as its service takes
   over.
4. Remove caddy-tailscale's configuration, secret, and tofu key from
   imperishable-night, and delete the old node state.
5. Rewrite the [tailnet policy's](../tailnet.md) target and rollout so
   sites are services, and update risks 4 and 5 in the
   [threat model](../threat-model.md).
6. Drop the root key from imperishable-night once no site there uses
   `tls internal`. The root stays trusted fleet-wide while
   lotus-land-story serves sites with it.
7. Give lolk the same configuration when its Caddy gets sites, through
   the shared Caddy module the
   [lolk migration](../legacy-of-lunatic-kingdom/2026-11-01-migrating-to-nixos.md)
   plans.

[services]: https://tailscale.com/docs/features/tailscale-services
[https]: https://tailscale.com/kb/1153/enabling-https
[serve]: https://tailscale.com/kb/1312/serve
[ct-117]: https://github.com/tailscale/caddy-tailscale/issues/117
[ct-136]: https://github.com/tailscale/caddy-tailscale/pull/136
