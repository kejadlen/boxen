# Build imperishable-night on the host, activate it, and record switch or test.
imperishable-night action="switch":
    {{ if action =~ '^(switch|test)$' { "bin/record-deploy imperishable-night" } else { "" } }} \
    nixos-rebuild {{ action }} --sudo \
      --flake './imperishable-night#imperishable-night' \
      --target-host imperishable-night --build-host imperishable-night

# Run a playbook (default <host>/main.yml) against one host and record it.
[positional-arguments]
playbook host playbook=(host / "main.yml") *args:
    #!/usr/bin/env bash
    set -euo pipefail
    bin/record-deploy "$1" ansible-playbook --limit "$1" "${@:3}" "$2"

# Apply the tofu configuration and record it.
[positional-arguments]
apply *args:
    bin/record-deploy tofu tofu apply "$@"

# Run every linter and format check, reporting all failures.
lint:
    #!/usr/bin/env bash
    set -uo pipefail
    status=0
    rumdl check . || status=1
    nixfmt --check $(jj file list 'glob:**/*.nix') || status=1
    tofu fmt -check $(jj file list 'glob:**/*.tf') || status=1
    ansible-lint || status=1
    # Templates are Jinja, not shell, until Ansible renders them.
    shellcheck $(jj file list 'glob:"**/*.sh" ~ glob:"**/templates/**"' bin/record-deploy bin/tofu-state-key) || status=1
    exit "$status"
