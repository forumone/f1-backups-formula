#!/bin/bash

#####
# Configuration

# Which MySQL host to target
readonly mysql_host='{{ host }}'

# Which MySQL port to target
readonly mysql_port='{{ port }}'

mysql_connect_args=(
  --defaults-file=/root/.my.cnf
  --host="$mysql_host"
  --port="$mysql_port"
)

#####
# Exported functions

ping_server() {
  mysql "${mysql_connect_args[@]}" --batch --execute ''
}

list_all_databases() {
  mysql "${mysql_connect_args[@]}" \
    --batch \
    --skip-column-names \
    --execute 'SHOW DATABASES'
}

dump_database() {
  mysqldump "${mysql_connect_args[@]}" \
    --single-transaction \
    --opt \
    "$1"
}

is_ignored_database() {
  [[ "$1" =~ ^(information_schema|performance_schema|mysql|sys|tmp)$ ]]
}
