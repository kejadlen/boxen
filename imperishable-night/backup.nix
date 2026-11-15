{
  config,
  lib,
  pkgs,
  ...
}:

let
  # vmbackup matches VictoriaMetrics' version.
  vmbackupImage =
    lib.replaceStrings [ "/victoria-metrics:" ] [ "/vmbackup:" ]
      config.virtualisation.oci-containers.containers.victoria-metrics.image;
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/gotosocial/backup 0700 root root -"
    "d /var/lib/postgresql-dump 0700 root root -"
    "d /var/lib/victoria-metrics-backup 0700 root root -"
  ];

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
      # The Victorias' telemetry churns too much to keep, apart from
      # VictoriaMetrics' snapshot, which has its own job.
      exclude = [
        "/var/lib/containers"
        "/var/lib/postgresql"
        "/var/lib/victoria-logs"
        "/var/lib/victoria-metrics"
        "/var/lib/victoria-metrics-backup"
        "/var/lib/victoria-traces"
      ];
      # Waits out the other host's prune, which locks the shared repository.
      extraBackupArgs = [
        "--retry-lock=30m"
        "--tag=long-term"
        "--exclude-file=/run/restic-backups-daily/gotosocial-excludes"
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
        # gotosocial's writes restart .backup's copy; see docs/research/2026-11-12-sqlite-backups.md.
        # VACUUM INTO refuses an existing file, which a failed run can leave behind.
        rm -f /var/lib/gotosocial/backup/sqlite.db.tmp
        # SQLite would replay a WAL left beside the old copy over the new one.
        ${pkgs.sqlite}/bin/sqlite3 /var/lib/gotosocial/data/sqlite.db \
          "VACUUM INTO '/var/lib/gotosocial/backup/sqlite.db.tmp'" &&
          rm -f /var/lib/gotosocial/backup/sqlite.db-wal /var/lib/gotosocial/backup/sqlite.db-shm &&
          mv /var/lib/gotosocial/backup/sqlite.db.tmp /var/lib/gotosocial/backup/sqlite.db || exit
        # Every other account's directory is remote media that gotosocial re-fetches.
        ids=$(${pkgs.sqlite}/bin/sqlite3 -readonly /var/lib/gotosocial/backup/sqlite.db \
          'select id from accounts where domain is null') || exit
        if [ -z "$ids" ]; then
          echo "no local gotosocial accounts found"
          exit 1
        fi
        {
          echo '/var/lib/gotosocial/data/*'
          for id in $ids; do echo "!/var/lib/gotosocial/data/$id"; done
        } > /run/restic-backups-daily/gotosocial-excludes
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

  # vmbackup rewrites as many parts as VictoriaMetrics merges, so its snapshots
  # get their own tag and a week of retention.
  services.restic.backups.victoria-metrics = {
    inherit (config.services.restic.backups.daily) repository passwordFile extraOptions;
    paths = [ "/var/lib/victoria-metrics-backup" ];
    extraBackupArgs = [
      "--retry-lock=30m"
      "--tag=victoria-metrics"
    ];
    pruneOpts = [
      "--retry-lock=30m"
      "--host=imperishable-night"
      "--tag=victoria-metrics"
      "--keep-within-daily=7d"
    ];
    # The daily job pulls it in.
    timerConfig = null;
    # A copy of the live data directory isn't guaranteed consistent; a snapshot is.
    backupPrepareCommand = ''
      ${config.virtualisation.podman.package}/bin/podman run --rm --network observability \
        --volume /var/lib/victoria-metrics:/storage:ro \
        --volume /var/lib/victoria-metrics-backup:/backup \
        ${vmbackupImage} \
        -storageDataPath=/storage \
        -snapshot.createURL=http://victoria-metrics:8428/snapshot/create \
        -dst=fs:///backup
    '';
  };

  # A failed snapshot fails the whole run, which healthchecks.io reports as a missed ping.
  systemd.services.restic-backups-daily = {
    requires = [ "restic-backups-victoria-metrics.service" ];
    after = [ "restic-backups-victoria-metrics.service" ];
  };
}
