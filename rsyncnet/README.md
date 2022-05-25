# rsyncnet formula

This formula is composed of 2 scripts:
1. `rsync-database.sh`: this script calls the `dump-database.sh` script from the `backups` formula to create and rsync database backups.
2. `rsync-files.sh`: this script rsyncs backups from either an OFS mount and/or paths defined in pillar.  For environments not using ObjectiveFS, a flag must be set to not mount the ObjectiveFS snapshot directory.

## Example Usage

In the SaltStack `top.sls` file, make sure to call both the `backups` and `rsyncnet` formulas.

Pillar Example:
```
backups:
  mail:
    # Optional
    to: sysadmins@forumone.com
    from: backups@byf1.dev

    # Set to True to be notified regardless of backup script status. By default,
    # this will only send mail on errors.
    on_success: False

  # Optional - sets backup_root var which sets the location where database
  # dumps are generated.  Defaults to /var/lib/backups
  dir: /var/lib/backups

  database:
    hosts:
      # MySQL only needs host and port
      mysql:
        type: mysql
        host: ro-mysql
        port: 3306

      # Optional - only set if PostgreSQL is in use.
      # User is required for Postgres connections
      postgres-prod:
        type: postgres
        host: ro-psql-prod
        port: 5432
        user: master

      # Optional - only set if PostgreSQL is in use.
      # User is required for Postgres connections
      postgres-preprod:
        type: postgres
        host: ro-psql-preprod
        port: 5432
        user: master

  rsync:
    # Optional - defaults to True.  Set to False if you need to backup
    # an environment that isn't using ObjectiveFS
    from_snapshot: False

    # Optional - allows an override of the destination
    # host: rsyncbackup

    # Optional when using ObjectiveFS snapshots, *required* when using path based backups.
    # Do not add /mnt/snapshot/vhosts or /var/www/vhosts; that path is synced specially using an OFS snapshot.
    paths:
      - /etc
      - /srv

    # Required - this is the RSYNC.NET user ID.  Each client has a userid pre-assigned.
    user: USER

    # Optional
    # Use this list to only sync some databases. If omitted, it will sync everything in backups:database:hosts.
    databases:
      - mysql
    ```