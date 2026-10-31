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
just imperishable-night
```

The recipe runs `nixos-rebuild switch` against the host. Pass another
action, such as `just imperishable-night boot` or
`just imperishable-night dry-activate`, to run that action instead. The
host builds the system, so macOS needs no Linux builder. SSH to the
host works only over the tailnet.
