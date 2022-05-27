#!/bin/bash

set -euo pipefail

#####
# Configuration

# Who gets sent this weekly report
readonly mail_to='{{ mail_to }}'

# The sender of the notification email
readonly mail_from='{{ mail_from }}'

#####
# Runtime values

# The timestamp we want journalctl to start looking at. Use 8 days in order to
# allow for some overlap.
since="$(date --date="-8 days" +%Y-%m-%d)"

#####
# Report script

# The 'statuses' variable below is a multiline string resulting from querying
# journald for the below conditions:
#
# 1. `--system` asks for the system-level journal (the default for root, but
#    it's better to be explicit)
# 2. `--no-pager` unconditionally prevents journalctl from using a pager.
# 3. `--identifier=backup-status` asks for only messages matching the given syslog
#    identifier.
# 4. `--since="$since"` only searches for messages beginning with the formatted
#    date.
statuses="$(journalctl --system --no-pager --identifier=backup-status --since="$since")"

(
  echo "Weekly report for $(hostname)"
  echo "About this message:"
  echo
  # Be kind to plain text output and respect the rulers here:
  #
  #    "0         1         2         3         4         5         6         7         8"
  #    "012345678901234567890123456789012345678901234567890123456789012345678901234567890"
  echo "Each line below this section is a log message from this server's journald. The"
  echo "first line is the time range searched by this report, followed by statuses"
  echo "reported from backup scripts."
  echo
  echo "$statuses"
  echo
  echo "Missing entries in this output may be due to the given job still running or this"
  echo "script failing to capture the output."
) | mailx -r "$mail_from" -s "$(hostname) weekly report" "$mail_to"
