# Build imperishable-night on the host and activate it.
imperishable-night action="switch":
    nixos-rebuild {{ action }} --sudo \
      --flake './imperishable-night#imperishable-night' \
      --target-host imperishable-night --build-host imperishable-night

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
    shellcheck $(jj file list 'glob:"**/*.sh" ~ glob:"**/templates/**"' bin/tofu-state-key) || status=1
    exit "$status"
