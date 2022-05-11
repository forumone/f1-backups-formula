#!/bin/bash
#set -e

export HOME=/root

LOCKFILE=/tmp/prebackup.lock
RSYNC_HOST=rsyncbackup
PAYLOAD=/etc/rsync-backup.txt
FIRST_RUN=/root/.rsync_first_run

function run {
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then
       echo "Error with $1"
    fi
    return $status
}


touch $LOCKFILE

echo "Backup beginning"

# Toggle mysqlbackups
if [[ "$1" == "dumpdbs" ]]
then
  date=`date -I`
  dir=/var/lib/mysqlbackups
  databases=`/usr/bin/mysql -e 'show databases' -s --skip-column-names | /bin/grep -v information_schema | /bin/grep -v performance_schema`
  file=$date.sql.gz
  test -d $dir || /bin/mkdir -p $dir
  echo "Dumping databases"
  for i in $databases; do run /usr/bin/mysqldump --opt --single-transaction $i |gzip > $dir/$i.$file; done
  echo "Finished dumping databases"
  run /usr/bin/find $dir -ctime +7 -delete
fi

if [ -f $FIRST_RUN ]; then
  run /usr/bin/rsync -arz --delete-after -e '/usr/bin/ssh' --files-from=$PAYLOAD / $RSYNC_HOST: || echo "Backup problem"
else
  run /usr/bin/rsync -ar --whole-file -e '/usr/bin/ssh -c arcfour' --files-from=$PAYLOAD / $RSYNC_HOST: || echo "Backup problem"
/bin/touch $FIRST_RUN
fi

rm -f $LOCKFILE

echo "Backup finished"
