#!/bin/bash
# shellcheck enable=avoid-nullary-conditions

set -euo pipefail

#####
# Configuration
#
# Variables here are configuration values determined by Salt.

# Host to rsync to
readonly rsync_host='{{ rsync_host }}'

# File listing to use
readonly rsync_payload='{{ rsync_payload }}'

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

# Determines if this is the first run of rsync or not
readonly rsync_first_run='/root/.rsync_first_run'

# Name of the lockfile preventing overlapping runs of this script
readonly lockfile="/var/run/rsync-files.lock"

# Name of the log file we copy output to
logfile="$(mktemp --tmpdir rsync-files.log.XXXXXXXXXX)"

# Open the log file as a file descriptor to pass into other commands
# NB. Lockfile FD is 10
exec 11>"$logfile"
readonly log_fd=11

# The backup date. Used to identify both the OFS snapshot as well as archive tarballs.
date="$(date +%Y-%m-%d)"

# Timestamp used to identify archive tarballs
timestamp="$date-$(date +%H-%M-%S)"

#####
# Functions
#
# Behavior used elsewhere in the script. Moved here to keep the main script
# logic fairly concise.

# Output an informational notice
log_info() {
  echo "[INFO]" "$@" >&$log_fd
  logger --tag rsync-files --id $$ -- "$*"
}

# Output an error message
log_error() {
  echo "[ERROR]" "$@" >&$log_fd
  logger --tag rsync-files --id $$ --priority user.err -- "$*"
}

# Notify backup status via email
notify_backup_status() {
  local status="$1"
  mailx -r "$mail_from" -s "rsync backup $status: $(hostname)" "$mail_to" <"$logfile"
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

  # Unmount the snapshot before we send email, in order to report its status. It
  # is not a catastrophe if the snapshot can't be unmounted (it can't be, here
  # in this error handler), but it is worth surfacing.
  if test -f /mnt/snapshot/README; then
    log_info "Unmounting OFS snapshot"
    if ! umount /mnt/snapshot 2>&$log_fd; then
      log_error "Failed to umount /mnt/snapshot"
    fi
  fi

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
# Sync script

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

if test -f /mnt/snapshot/README; then
  log_info "Unmounting stale snapshot mount"
  umount /mnt/snapshot 2>&$log_fd
fi

log_info "Ensuring directory /mnt/snapshot exists"
mkdir -p /mnt/snapshot 2>&$log_fd

# Find and mount the latest OFS snapshot
ofs_bucket="$(awk '$2 == "/var/www" { print $1 }' /etc/fstab)"
if test -z "$ofs_bucket"; then
  log_error "Failed to find OFS bucket mounted on /var/www"
  exit 1
fi

# Make sure that what we found is actually an S3 bucket
if [[ "$ofs_bucket" != s3://* ]]; then
  log_error "/var/www is mounted to $ofs_bucket which is not an S3 bucket"
  exit 1
fi

log_info "Found OFS bucket: $ofs_bucket"

# Find the latest snapshot (-sz: list snapshots (-s) in UTC (-z)). The /^s3/
# condition in awk avoids capturing the first line of output (the column names).
ofs_snapshot="$(/sbin/mount.objectivefs list -sz "$ofs_bucket@$date" 2>&$log_fd | awk '/^s3/ { latest = $1 } END { print latest }')"
if test -z "$ofs_snapshot"; then
  log_error "Could not find OFS snapshot in $ofs_bucket matching date $date"
  exit 1
fi

log_info "Mounting OFS snapshot $ofs_snapshot to /mnt/snapshot"
/sbin/mount.objectivefs "$ofs_snapshot" "/mnt/snapshot" 2>&$log_fd

# Validate
if ! test -f "/mnt/snapshot/README"; then
  log_error "Failed to validate mount of OFS snapshot $ofs_snapshot: no README present"
  exit 1
fi

# Flag to determine if the sync succeeded or failed. We attempt every operation
# and report failure in aggregate.
sync_ok=1

log_info "Ensuring /var/www/vhosts exists on the remote"
ssh "$rsync_host" mkdir -p var/www/vhosts 2>&$log_fd

if test -f "$rsync_first_run"; then
  log_info "Performing file sync"
  if ! rsync -arz --delete-after -e /usr/bin/ssh --files-from="$rsync_payload" / "$rsync_host:" 2>&$log_fd; then
    log_error "Failed to rsync files from $rsync_payload to $rsync_host"
    sync_ok=
  fi

  if ! rsync -arz --delete-after -e /usr/bin/ssh /mnt/snapshot/vhosts "$rsync_host:var/www/vhosts/" 2>&$log_fd; then
    log_error "Failed to rsync files from /mnt/snapshot/vhosts to $rsync_host"
    sync_ok=
  fi
else
  log_info "Performing first-run file sync"
  if ! rsync -ar --whole-file -e /usr/bin/ssh --files-from="$rsync_payload" / "$rsync_host:" 2>&$log_fd; then
    log_error "Failed to rsync files from $rsync_payload to $rsync_host"
    sync_ok=
  fi

  if ! rsync -ar --whole-file -e /usr/bin/ssh /mnt/snapshot/vhosts "$rsync_host:var/www/vhosts/" 2>&$log_fd; then
    log_error "Failed to rsync files from /mnt/snapshot/vhosts to $rsync_host"
    sync_ok=
  fi

  # Note an error but don't bail; this is not considered catastrophic.
  if ! touch "$rsync_first_run"; then
    log_error "Failed to update $rsync_first_run"
  fi
fi

if test -z "$sync_ok"; then
  log_error "One or more sync operations failed."
  exit 1
fi

end="$(date +%s)"

elapsed=$((end - start))
log_info "Done in $(format_duration $elapsed)"
