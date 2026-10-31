# boxen

`nix develop` opens a shell with the repository's tools: Ansible and its
collections, OpenTofu, sops, age, and the NixOS deploy tools.

Playbooks run from the repository root against a single host:

```sh
ansible-playbook -l <host> <host>/<playbook>.yml
```

imperishable-night runs NixOS instead of Ansible. Deploy its flake from
the repository root:

```sh
nixos-rebuild switch --sudo \
  --flake './imperishable-night#imperishable-night' \
  --target-host alpha@<ip> --build-host alpha@<ip>
```

The host builds the system, so macOS needs no Linux builder.
