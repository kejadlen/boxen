# boxen

`nix develop` opens a shell with the repository's tools: Ansible and its
collections, OpenTofu, sops, age, and the NixOS deploy tools.

Playbooks run from the repository root against a single host:

```sh
just playbook <host> [<host>/<playbook>.yml] [<ansible-playbook args>...]
```

The playbook defaults to `<host>/main.yml`. For a `--check` run, which
changes nothing, call `ansible-playbook -l <host>` directly so it isn't
recorded as a deploy.

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

`just apply` runs `tofu apply`, passing along any arguments.

These recipes run their command through `bin/record-deploy`, which then
pushes `deploy_success`, `deploy_duration_seconds`, and
`deploy_completed_timestamp` to VictoriaMetrics, labeled with the target
and the deployed jj change. That's the working copy, or its parent when
the working copy is empty. The personal dashboard annotates each deploy,
in red when the command failed or was interrupted. Only `switch` and
`test` count as imperishable-night deploys.
