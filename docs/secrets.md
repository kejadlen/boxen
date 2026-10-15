# Secrets

Host secrets live in `host_vars/<host>.sops.yml`, encrypted with
[sops](https://getsops.io) to a single [age](https://age-encryption.org)
key. The files are committed. Ansible decrypts them in memory, so playbooks use
the values like any other host var.
Non-secret host vars, like `versions`, go in the plaintext
`host_vars/<host>.yml`.

## Why sops

sops encrypts each value and leaves the keys in plaintext. A diff of an
encrypted file still shows which secrets changed, which Ansible Vault's
whole-file encryption doesn't. age keys are asymmetric, so encrypting only
needs the public key in `.sops.yaml`. Adding another recipient means
appending a public key and re-encrypting, not sharing a password.

## How the key reaches sops

The age private key exists only in 1Password. `.envrc` sets
`SOPS_AGE_KEY_CMD` to an `op read` command, so sops fetches the key from
1Password on each decrypt and nothing is written to disk. A shell without
that environment can't decrypt anything.

`.sops.yaml` has one creation rule that matches `host_vars/*.sops.yml` (or
`.sops.yaml`) and encrypts to the age public key.

## How Ansible decrypts

`ansible.cfg` enables the `community.sops.sops` vars plugin, which comes
from the `community.sops` collection in `requirements.yml`:

```ini
vars_plugins_enabled = host_group_vars,community.sops.sops
```

The plugin decrypts files ending in `.sops.yml`, `.sops.yaml`, or
`.sops.json`. Keep `host_group_vars` in the list: setting
`vars_plugins_enabled` replaces the default list, and without it the
plaintext `host_vars` files stop loading.

## What's in git

`host_vars/.gitignore` ignores everything except the `.sops.yml` files and
the whitelisted plaintext files. Today the tracked files are the following:

- `legacy-of-lunatic-kingdom.sops.yml`
- `legacy-of-lunatic-kingdom.yml`
- `lotus-land-story.sops.yml`
- `lotus-land-story.yml`
- `mountain-of-faith.sops.yml`

## What loads which file

`host_vars/<host>.sops.yml` is only read by the sops plugin and
`host_vars/<host>.yml` only by `host_group_vars`, which matches exact
`<host>.yml`/`.yaml`/`.json` names and never parses a `.sops.yml` as
plaintext. If the same key appears in both files, the plugins' results
deep-merge with the sops values winning — that's plugin load order, not
documented precedence, so keep each key in exactly one file.

## Edit a secret

Open the file with sops, which decrypts it into `$EDITOR` and re-encrypts
on save:

```sh
sops host_vars/lotus-land-story.sops.yml
```

The same command creates a new `host_vars/<host>.sops.yml`, encrypted
through the creation rule.

## OpenTofu

OpenTofu keeps state in the gitignored `terraform.tfstate` and encrypts it
with AES-GCM. The key is 32 random bytes, base64-encoded, in the
`tofu-state-key` item in the Private vault. `bin/tofu-state-key` is an
[external key provider][external] that reads it with `op read`, so each
`tofu` command that touches state asks 1Password for it.

Provider credentials come from the `boxen-*` items in the same vault, read
through the 1Password provider's ephemeral `onepassword_item` so they never
reach state. The provider authenticates through the desktop app, which needs
Settings → Developer → "Integrate with 1Password SDKs" turned on.

[external]: https://opentofu.org/docs/language/state/encryption/

## Losing the key

`.sops.yaml` lists one recipient. If the 1Password item is lost, every
`.sops.yml` file is unrecoverable. A second recipient, such as a recovery
key stored offline, would remove that single point of failure.
