# Build imperishable-night on the host and activate it.
imperishable-night action="switch":
    nixos-rebuild {{ action }} --sudo \
      --flake './imperishable-night#imperishable-night' \
      --target-host imperishable-night --build-host imperishable-night
