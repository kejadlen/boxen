{
  config,
  pkgs,
  ...
}:

{
  systemd.tmpfiles.rules = [ "d /var/lib/postgresql-dump 0700 root root -" ];

  sops.secrets."restic/password" = { };
  sops.secrets."restic/healthcheck" = { };
  sops.templates."restic.env".content = ''
    HEALTHCHECK=https://hc-ping.com/${config.sops.placeholder."restic/healthcheck"}
  '';

  programs.ssh.knownHosts.legacy-of-lunatic-kingdom.publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG/+SIFLbFe3hXp3l0dJSE7J4DpQkEEk//62kMiQsWOZ";

  # Shares lotus-land-story's repository; restic's hostname keeps the snapshots apart.
  services.restic.backups.daily =
    let
      ping = path: ''
        ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 10 \
          --retry 5 --output /dev/null "$HEALTHCHECK${path}" || true
      '';
    in
    {
      repository = "sftp:restic@legacy-of-lunatic-kingdom:/mnt/data/restic";
      passwordFile = config.sops.secrets."restic/password".path;
      environmentFile = config.sops.templates."restic.env".path;
      # lolk's restic user authorizes the host key, so there's no separate client key.
      extraOptions = [
        "sftp.command='ssh restic@legacy-of-lunatic-kingdom -i /etc/ssh/ssh_host_ed25519_key -s sftp'"
      ];
      paths = [ "/var/lib" ];
      # A file-level copy of the running cluster isn't restorable; the dump is.
      exclude = [
        "/var/lib/containers"
        "/var/lib/postgresql"
      ];
      # Waits out the other host's prune, which locks the shared repository.
      extraBackupArgs = [
        "--retry-lock=30m"
        "--tag=long-term"
      ];
      pruneOpts = [
        "--retry-lock=30m"
        "--host=imperishable-night"
        "--tag=long-term"
        "--keep-within-daily=1m"
        "--keep-within-weekly=3m"
        "--keep-within-monthly=2y"
        "--keep-within-yearly=100y"
      ];
      timerConfig = {
        OnCalendar = "03:00";
        Persistent = true;
      };
      # Last, so a failed dump fails the run. The rename keeps the previous dump if it does.
      backupPrepareCommand = ''
        date +%s > /run/restic-backups-daily/start
        ${ping "/start"}
        # Writes under /var/lib/pro-tacts, so the file backup picks it up.
        ${config.virtualisation.podman.package}/bin/podman exec pro-tacts rake db:dump || exit
        ${pkgs.util-linux}/bin/runuser -u postgres -- ${config.services.postgresql.package}/bin/pg_dumpall \
          > /var/lib/postgresql-dump/pg_dumpall.sql.tmp &&
          mv /var/lib/postgresql-dump/pg_dumpall.sql.tmp /var/lib/postgresql-dump/pg_dumpall.sql
      '';
      # Pushes the same backup_* series as lotus-land-story's backup.sh.
      backupCleanupCommand = ''
        push() {
          ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 10 \
            --retry 3 --data-binary "$1" https://metrics/api/v1/import/prometheus || true
        }

        end=$(date +%s)
        start=$(cat /run/restic-backups-daily/start 2>/dev/null || echo "$end")
        ts=''${end}000 # milliseconds
        l='{job="backup",host="imperishable-night"}'
        if [ "$SERVICE_RESULT" = success ]; then
          ${ping ""}
          push "$(printf '%s\n' \
            "backup_success$l 1 $ts" \
            "backup_duration_seconds$l $((end - start)) $ts" \
            "backup_completed_timestamp$l $end $ts")"
        else
          ${ping "/fail"}
          push "backup_success$l 0 $ts"
        fi
      '';
    };
}
