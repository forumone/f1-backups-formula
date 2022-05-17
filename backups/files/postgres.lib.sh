#!/bin/bash

#####
# Configuration

# Which Postgres host to target
readonly postgres_host='{{ host }}'

# Which Postgres port to target
readonly postgres_port='{{ port }}'

# Which Postgres user to log in as
readonly postgres_user='{{ user }}'

# Arguments for connecting to Postgres
postgres_connect_args=(
  --host="$postgres_host"
  --port="$postgres_port"
  --username="$postgres_user"

  # Disable the password prompt for all Postgres commands. This is an unattended
  # script and we should be relying solely on .pgpass
  --no-password
)

ping_server() {
  psql "${postgres_connect_args[@]}" --command ''
}

list_all_databases() {
  psql "${postgres_connect_args[@]}" \
    --no-align \
    --tuples-only \
    --command 'SELECT datname FROM pg_database WHERE NOT datistemplate'
}

dump_database() {
  pg_dump "${postgres_connect_args[@]}" \
    --format=plain \
    --no-owner \
    --no-privileges \
    "$1"
}

is_ignored_database() {
  [[ "$1" =~ ^(rdsadmin|postgres|master)$ ]]
}
