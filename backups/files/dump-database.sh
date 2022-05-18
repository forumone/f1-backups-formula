#!/bin/bash
# shellcheck enable=avoid-nullary-conditions

set -euo pipefail

#####
# Arguments

# This script expects a single argument, identifier, which corresponds to a
# number of values in this and other scripts:
#
# 1. It names the configuration file within /opt/backups/lib.
# 2. It names the subdirectory within the backup root (e.g., "/var/lib/backups/$identifier")
# 3. It names the lockfile and log tag.
readonly identifier="${1:?USAGE: $0 <identifier>}"

#####
# Configuration

# Where to store backups.
readonly backup_root='{{ backup_root }}'

# Who to notify on backup failures
readonly mail_to='{{ mail_to }}'

# The sender of the notification email
readonly mail_from='{{ mail_from }}'

# If set (and not empty), send email on successful syncs (not just failures)
readonly mail_on_success='{{ mail_on_success }}'

#####
# Runtime values

# Name of the lockfile preventing overlapping runs of this script
readonly lockfile="/var/run/database-$identifier-backup.lock"

# Name of the script holding database-specific functions
readonly config_file="/opt/backups/lib/$identifier.sh"

# Name of the directory where backups for this database endpoint are stored
readonly backup_dir="$backup_root/$identifier"

# Name of the log file we copy output to
logfile="$(mktemp --tmpdir "$identifier.log.XXXXXXXXXX")"

# Open the log file as a file descriptor to pass into other commands
# NB. Lockfile FD is 10
exec 11>"$logfile"
readonly log_fd=11

# Dates and times for identifying generated files
date="$(date +%Y-%m-%d)"
timestamp="$date-$(date +%H-%M-%S)"

#####
# Functions
#
# Behavior used elsewhere in the script. Moved here to keep the main script
# logic fairly concise.

# Output an informational notice
log_info() {
  echo "[INFO]" "$@" >&$log_fd
  logger --tag "$identifier" --id $$ -- "$*"
}

# Output an error message
log_error() {
  echo "[ERROR]" "$@" >&$log_fd
  logger --tag "$identifier" --id $$ --priority user.err -- "$*"
}

# Notify backup failure via email
notify_backup_status() {
  local status="$1"
  mailx -r "$mail_from" -s "$(hostname) database backup for $identifier: $status" "$mail_to" <"$logfile"
}

on_script_exit() {
  # Save the script exit code so we don't clobber it with our commands.
  exit=$?

  # Explicitly let stuff fail here. This is the last function that runs, so we
  # want to clean up as much as we can.
  set +e
  set +o pipefail

  # Send notification emails on two occasions:
  # 1. Something bad happened and we've trapped a failure exit, or
  # 2. We were asked to send emails even on successes.
  #
  # Note that this happens first because otherwise we'll blow away the log file.
  if test $exit -ne 0; then
    notify_backup_status failure
  elif test -n "$mail_on_success"; then
    log_info "Mailing on success because \$mail_on_success=$mail_on_success, which is not empty"
    notify_backup_status success
  fi

  # Clean up the files we generated
  rm -f "$lockfile"
  rm -f "$logfile"

  return $exit
}

#####
# Database dump script

log_info "Sourcing file $config_file"

# shellcheck disable=SC1090
. "$config_file" 2>&$log_fd

# Make sure the file we sourced works and exported the functions we expect
startup_ok=1
for expected in ping_server list_all_databases dump_database is_ignored_database; do
  # Use `type -t` to determine
  type="$(type -t "$expected")"
  case "$type" in
    '')
      log_error "Function '$expected' not found"
      startup_ok=
      ;;

    function)
      # This is okay; we expect these to be functions
      ;;

    *)
      # This is okay, but not expected
      log_info "Note: Found '$expected' of type '$type' instead of function. This may or may not be okay."
      ;;
  esac
done

log_info "Pinging database to determine connectivity"
if ! ping_server 2>&$log_fd; then
  log_error "Failed to connect to database"
  startup_ok=
fi

if test -z "$startup_ok"; then
  log_error "Refusing to proceed due to failed startup"

  # Notify manually of startup failures
  notify_backup_status failure
  exit 1
fi

# Open the lockfile and get an exclusive lock on it. If we can't, fail.
exec 10<>"$lockfile"
if ! flock --nonblock --exclusive 10; then
  lock_contents="$(cat <&10)"
  log_error "Could not obtain lock for $lockfile (lock contents: $lock_contents)"

  # Notify backup failure manually: the cleanup trap isn't safe to run
  notify_backup_status failure
  exit 1
fi

# Annotate the lock now that we know we have it.
echo "Started by pid $$ at $timestamp" >&10

# Now that we're running exclusively, register the script exit handler
trap on_script_exit EXIT

log_info "Determining databases to back up"

database_count=0
databases=()
while read -r line; do
  if is_ignored_database "$line"; then
    log_info "Ignoring database $line"
  else
    databases+=("$line")
    ((database_count++))
  fi
done < <(list_all_databases 2>&$log_fd)

if test "$database_count" -eq 0; then
  log_error "Error: the databases array is empty"
  exit 1
fi

# Flag to determine if the backup operation was successful
backup_ok=1

# Dump each database in serial. Even if one dump fails, we try to dump the others.
for database in "${databases[@]}"; do
  outfile="$backup_dir/$database-$date.sql.gz"

  log_info "Dumping database $database to $outfile"
  if ! dump_database "$database" 2>&$log_fd | gzip 2>&$log_fd >"$outfile"; then
    log_error "Failed to dump $database to $outfile (exit code $?)"

    backup_ok=
    continue
  fi

  log_info "Backed up to $outfile"
done

if test -n "$backup_ok"; then
  # Rotate backups if everything succeeded
  log_info "Rotating backups in $backup_dir"
  if ! find "$backup_dir" -type f -ctime +7 -delete 2>&$log_fd; then
    # We don't consider backup rotation failure to be an email-worthy emergency: it will use slightly more disk space,
    # but it is not as critical as failing to generate backups in the first place.
    log_error "Failed to rotate backups (exit code $?)"
  fi
else
  log_error "One or more databases failed to back up. Please see the log contents above this message."
  log_error "NOTE: Backups have not been rotated."
  exit 1
fi
