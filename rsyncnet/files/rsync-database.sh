#!/bin/bash
# shellcheck enable=avoid-nullary-conditions

set -euo pipefail

#####
# Arguments

# See database/files/dump-database.sh for more details on this argument
readonly identifier="${1:?USAGE: $0 <identifier>}"

#####
# Configuration
#
# Variables here are configuration values determined by Salt.

# Root directory for DB backups
readonly backup_root='{{ backup_root }}'

# Host to rsync to
readonly rsync_host='{{ rsync_host }}'

# Who to notify on backup failures
readonly mail_to='{{ mail_to }}'

# The sender of the notification email
readonly mail_from='{{ mail_from }}'

# If set (and not empty), send email on successful syncs (not just failures)
readonly mail_on_success='{{ mail_on_success }}'

#####
# Runtime Values
#
# These are values used only by the script; don't change these unless you know
# what you're doing.

# Name of the directory where backups for this database host are stored
readonly local_backup_dir="$backup_root/$identifier/"

# Same as local_backup_dir, but with the leading / stripped off.
readonly remote_backup_dir="${local_backup_dir#/}"

# Name of the lockfile preventing overlapping runs of this script
readonly lockfile="/var/run/rsync-databse-$identifier.lock"

# Name of the log file we copy output to
logfile="$(mktemp --tmpdir "rsync-database-$identifier.log.XXXXXXXXXX")"

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
  logger --tag "rsync-database-$identifier" --id $$ -- "$*"
}

# Output an error message
log_error() {
  echo "[ERROR]" "$@" >&$log_fd
  logger --tag "rsync-database-$identifier" --id $$ --priority user.err -- "$*"
}

# Notify backup failure via email
notify_backup_status() {
  local status="$1"
  local message
  message="$(hostname) rsync backup for $identifier: $status"

  logger --tag backup-status "$message"
  mailx -r "$mail_from" -s "$message" "$mail_to" <"$logfile"
}

# Pretty-print a duration (in seconds) as either "XXmYYs" or "XhYYmZZs",
# depending on whether or not the duration is >1 hour.
format_duration() {
  local duration="$1"

  local hours_in_seconds=3600
  local hours=$((duration / hours_in_seconds))
  duration=$((duration % hours_in_seconds))

  local minutes_in_seconds=60
  local minutes=$((duration / minutes_in_seconds))
  duration=$((duration % minutes_in_seconds))

  if test "$hours" -gt 0; then
    printf "%dh%0dm%0ds" "$hours" "$minutes" "$duration"
  else
    printf "%0dm%0ds" "$minutes" "$duration"
  fi
}

# Cleanup function. Once the lockfile is registered, this should be registered
# as the EXIT trap in order to clean up resources regardless of when (and how)
# the script exits.
#
# NB. It is NOT safe to register this handler until we know that we have a lock
# on $lockfile.
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
# Backups

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

start="$(date +%s)"

log_info "Running '/opt/backups/bin/dump-database.sh $identifier'; its status will be reported separately"
bash "/opt/backups/bin/dump-database.sh" "$identifier"

log_info "Ensuring $remote_backup_dir exists on the remote"
ssh "$rsync_host" mkdir -p "$remote_backup_dir" 2>&$log_fd

log_info "Syncing $local_backup_dir to rsync"
rsync -arz --delete-after -e /usr/bin/ssh "$local_backup_dir" "$rsync_host:$remote_backup_dir" 2>&$log_fd

end="$(date +%s)"

elapsed=$((end - start))
log_info "Done in $(format_duration $elapsed)"
