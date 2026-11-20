# Chainguard against the threat model

[Chainguard][chainguard] sells hardened container images, rebuilt from
source, with signed SBOMs and build provenance. This evaluation checks
whether any of it addresses a risk in the [threat model](../threat-model.md).
The outcome is that it doesn't change the model. The fix it comes closest
to, making image updates wait for a reviewed bump, is digest pinning,
which [risk 8](../threat-model.md#8-github-as-the-root-of-trust) already
names and which needs nothing from Chainguard.

[chainguard]: https://www.chainguard.dev/

## What imperishable-night runs

`imperishable-night/containers.nix` and its neighbors pull the following
images:

| Source | Images |
|---|---|
| The fleet's own, on `ghcr.io/kejadlen` | `caddy-kejadlen`, `quire` (`:latest`), `ketchup`, `pro-tacts`, `soju` |
| Docker Hub | Authelia, Grafana, Redis, miniflux, GoToSocial |
| Other registries | paperless-ngx and homebox on ghcr.io, calibre-web on lscr.io, and the VictoriaMetrics images on quay.io |

Every image except quire's pins a tag. A tag is a pointer its publisher
can move.

## How it maps to the risks

The following table lists each part of the model that Chainguard could
touch, and what it would change:

| Part of the model | What Chainguard offers | Effect |
|---|---|---|
| The poisoned upstream actor and the assumption that upstream images aren't malicious | Images built from source in Chainguard's pipeline, with signed provenance | Moves trust from each image's publisher to Chainguard, but only for images Chainguard carries |
| [Risk 8](../threat-model.md#8-github-as-the-root-of-trust), GitHub as the root of trust | Nothing for the fleet's own images | None. ketchup already builds a Nix image, which gives the minimal, reproducible base that Wolfi and apko would |
| Assumption 5, a compromised container as a foothold, and risks [4](../threat-model.md#4-a-linodes-secrets-reach-past-it), [6](../threat-model.md#6-header-trust-apps-on-a-shared-network), and [14](../threat-model.md#14-authelia-decides-who-joins-the-tailnet) | Distroless images with no shell or package manager | Makes work after an exploit clumsier, but a foothold still reads every secret mounted into the container |
| Patching | Daily rebuilds with few known CVEs | Lands only when a bump deploys, the same as today |

The third-party images that matter most are Authelia, GoToSocial,
paperless-ngx, and miniflux. Whether Chainguard's catalog carries them is
unchecked. Redis and Grafana are the likeliest to be there.

## The free tiers

Chainguard has two free offerings, and both fit poorly:

- Free public images serve only `:latest`, and sometimes `:latest-dev`,
  with no SLA ([versions][cg-versions]). Version tags moved to the paid
  catalogs ([tag change][cg-tags]). Following `:latest` would undo the
  version pins.
- Catalog Starter, launched on 2026-03-17, gives five images of your
  choice with unlimited pulls ([announcement][cg-starter-blog]).
  Chainguard says it covers every supported version, but its CVE SLA
  doesn't apply ([Catalog Starter][cg-starter]). It became self-serve in
  November 2026 ([SiliconAngle][siliconangle]).

[cg-versions]: https://edu.chainguard.dev/chainguard/containers/versions/
[cg-tags]: https://chainguard.dev/unchained/scaling-chainguard-images-with-a-growing-catalog-and-proactive-security-updates
[cg-starter-blog]: https://www.chainguard.dev/unchained/introducing-chainguard-catalog-starter
[cg-starter]: https://edu.chainguard.dev/chainguard/chainguard-images/about/catalog-starter/
[siliconangle]: https://siliconangle.com/?p=854462

## Enforcing signatures

Podman can refuse unsigned images through the `sigstoreSigned`
requirement in `containers-policy.json`
([containers-policy.json(5)][policy-json]). For the fleet's own images,
that would mean signing them in CI with cosign's keyless flow and
requiring that identity on pull.

It doesn't help risk 8. A keyless signature attests to the workflow that
ran, and an attacker who holds the GitHub account can run that same
workflow and get a valid signature. It stops only someone who holds a
registry token without repository access. Matching a CI identity may
also not work yet: containers/image matched only a subject email, and
CI certificates carry a URI ([issue][keyless-issue]).

[policy-json]: https://man.archlinux.org/man/containers-policy.json.5.en
[keyless-issue]: https://gitlab.com/dunn.dev/immutable/basef/-/issues/15

## Recommendation

Pin every image in `imperishable-night/containers.nix` by digest,
starting with quire's `:latest`. boxen deploys from the Mac, so a
malicious push to GitHub or Docker Hub then reaches a host only through
a bump someone reviewed. If Chainguard is worth trying anyway, Catalog
Starter's five slots fit Redis and Grafana, pinned by digest like the
rest.

## Open questions

- Does Chainguard's catalog carry Authelia, GoToSocial, paperless-ngx,
  or miniflux?
- Does Catalog Starter serve version tags, as Chainguard's announcement
  says, or only `:latest`?
- Has containers/image added URI or regex matching for Fulcio
  identities?
