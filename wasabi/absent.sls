/opt/wasabi:
  file.absent

/root/.aws:
  file.absent

/usr/sbin/mysqlbackup.sh:
  file.absent

/usr/sbin/postgresqlbackup.sh:
  file.absent

wasabi-daily:
  cron.absent:
    - identifier: wasabi-daily

wasabi-weekly:
  cron.absent:
    - identifier: wasabi-weekly

mysql-daily.sh:
  cron.absent:
    - identifier: mysql-daily-backup

psql-daily.sh:
  cron.absent:
    - identifier: postgresql-daily-backup