# Secrets management on imperishable-night

An evaluation of alternatives to sops-nix for imperishable-night's
secrets, prompted by risk 4 in the [threat model](../threat-model.md): a
foothold on the host yields every secret on it. The outcome is to keep
sops-nix and shrink what it holds. [Secrets](../secrets.md) describes
how sops-nix is set up.

## What a tool can and can't change

sops-nix decrypts every secret at activation with an age key derived
from the SSH host key on disk, and writes them to `/run/secrets`, where
root reads them all. No tool changes the first part: the host boots
unattended, so something on disk has to unlock the secrets, and a
foothold with root has that something. What the tools differ on is
scoping per service, central revocation and audit, exposure of the disk
image at rest, and what the host depends on at boot.

## Options

The following were weighed in November 2026:

| Option | What it changes | Why not now |
|---|---|---|
| agenix | Nothing. The same decrypt-at-activation model with age only and whole-file encryption | No gain, and per-key diffs are lost |
| systemd credentials (`LoadCredentialEncrypted=`) | Each unit sees only its own secret instead of a root-readable directory | `oci-containers` doesn't pass credentials to podman, so only host-native units such as Rex's login server benefit |
| A 1Password service account on the host ([opnix][opnix-mrjones] or [OpNix][opnix-brizzbuzz]) | Central revocation and a read log, from the account that's already the root of trust | A long-lived token on disk reaching a whole vault, a boot-time dependency on 1Password, and beta modules |
| OpenBao, Vault, or Infisical | Per-service tokens, short leases, dynamic credentials | A new service to run and secure, which would have to be up when a Linode boots, so it can't live at home ([direction](../direction.md)) |
| Full disk encryption | Protects the disk image and the Linode Backups snapshot, which holds the host key | Unlocking needs the console or a network unlock server with the same home-dependency problem. Whether Linode exposes a virtual TPM is unconfirmed |

## Outcome

Shrinking the inventory does more than swapping the tool. Scoping the
DNSimple token, keeping docket's Fastmail tokens off the host until
docket runs there, and removing Caddy's Tailscale auth key through
[Tailscale Services](../imperishable-night/2026-11-11-tailscale-services.md)
are all in the backlog. A second age recipient, which
[secrets](../secrets.md#losing-the-key) describes, fixes the loss case.

Revisit the 1Password service account once those land. The question
then is whether revocation and audit are worth a boot dependency, not
how many secrets sit on the host.

[opnix-mrjones]: https://github.com/mrjones2014/opnix
[opnix-brizzbuzz]: https://github.com/brizzbuzz/opnix
