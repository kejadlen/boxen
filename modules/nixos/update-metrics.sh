# shellcheck shell=bash
#
# Writes update metrics for node-exporter's textfile collector. Expects
# TEXTFILE_DIR, BRANCH (such as nixos-26.05), and REVISION, the deployed
# nixpkgs commit.

# Renamed into place so node-exporter never reads a half-written file.
write_metrics() {
  local name=$1
  cat >"$TEXTFILE_DIR/$name.prom.tmp"
  mv "$TEXTFILE_DIR/$name.prom.tmp" "$TEXTFILE_DIR/$name.prom"
}

# The same paths system.autoUpgrade compares before rebooting.
reboot_required() {
  local path
  for path in kernel kernel-modules initrd; do
    if [[ $(readlink --canonicalize "/run/booted-system/$path") != $(readlink --canonicalize "/run/current-system/$path") ]]; then
      echo 1
      return
    fi
  done
  echo 0
}

github() {
  curl --fail --silent --show-error --max-time 60 \
    --header 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/NixOS/nixpkgs/$1"
}

main() {
  # Before the network calls, so a GitHub outage only stales the branch metrics.
  write_metrics reboot <<EOF
# HELP node_reboot_required Whether the booted kernel, modules, or initrd differ from the current system's.
# TYPE node_reboot_required gauge
node_reboot_required $(reboot_required)
EOF

  local compare head_time deployed_time behind
  compare=$(github "compare/$REVISION...$BRANCH?per_page=1")
  head_time=$(github "commits/$BRANCH" | jq --raw-output '.commit.committer.date | fromdateiso8601')
  deployed_time=$(jq --raw-output '.base_commit.commit.committer.date | fromdateiso8601' <<<"$compare")
  behind=$(jq --raw-output '.ahead_by' <<<"$compare")

  write_metrics nixpkgs <<EOF
# HELP nixpkgs_branch_lag_seconds The branch head's commit time minus the deployed revision's.
# TYPE nixpkgs_branch_lag_seconds gauge
nixpkgs_branch_lag_seconds{branch="$BRANCH"} $((head_time - deployed_time))
# HELP nixpkgs_branch_commits_behind How many commits the branch head is ahead of the deployed revision.
# TYPE nixpkgs_branch_commits_behind gauge
nixpkgs_branch_commits_behind{branch="$BRANCH"} $behind
EOF
}

main "$@"
