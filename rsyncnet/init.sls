{% from 'backups/map.jinja' import mail_on_success, mail_from, mail_to with context %}

{% set rsync_host = salt['pillar.get']('backups:rsync:host', 'usw-s007.rsync.net') %}
{% set rsync_paths = salt['pillar.get']('backups:rsync:paths', ['/etc', '/srv']) %}

{% set all_db_identifiers = salt['pillar.get']('backups:database:hosts', {}).keys() %}
{% set identifiers = salt['pillar.get']('backups:rsync:databases', all_db_identifiers) %}

# Ensure dir exists and perms are correct
/root/.ssh:
  file.directory:
    - user: root
    - group: root
    - mode: 700

# Make sure rsync_id and rsync_id.pub are present
generate_rsync_key:
  cmd.run:
    - name: ssh-keygen -N '' -f /root/.ssh/rsync_id && chmod 600 /root/.ssh/rsync_id.pub
    - creates: /root/.ssh/rsync_id

ssh_config_exists:
  file.managed:
    - name: /root/.ssh/config
    - replace: False
    - user: root
    - group: root
    - mode: '0600'

# SSH Config for rsync, set hostname and user
/root/.ssh/config:
  file.append:
    - template: jinja
    - sources:
      - salt://rsyncnet/files/ssh-config
    - context:
        user: {{ pillar.rsync.user }}

"ssh-keyscan -H usw-s007.rsync.net >> ~/.ssh/known_hosts":
  cmd.run:
    - onlyif: /root/.ssh/config

# Copy ID to rsync.net
# temporary, run this manually
# scp /root/.ssh/rsync_id.pub rsyncbackup:.ssh/authorized_keys

# Add our paths from pillar
/etc/rsync-backup.txt:
  file.managed:
    - user: root
    - group: root
    - mode: '0600'
    - content: {{ rsync_paths | join("\n") | yaml_encode }}

/opt/rsync/bin:
  file.directory:
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

/opt/rsync/bin/rsync-files.sh:
  file.managed:
    - user: root
    - group: root
    - mode: 750
    - source: salt://rsyncnet/files/rsync-files.sh
    - template: jinja
    - context:
        rsync_host: {{ rsync_host }}
        mail_to: {{ mail_to }}
        mail_from: {{ mail_from }}
        mail_on_success: {{ "True" if mail_on_success else '' }}
    - require:
      - file: /opt/rsync/bin

/opt/rsync/bin/rsync-files.sh |& logger -t backups:
  cron.present:
    - identifier: rsyncbackup
    - user: root
    - hour: 2
    - minute: random

/opt/rsync/bin/rsync-database.sh:
  file.managed:
    - user: root
    - group: root
    - mode: 750
    - source: salt://rsyncnet/files/rsync-database.sh
    - template: jinja
    - context:
        mail_to: {{ mail_to }}
        mail_from: {{ mail_from }}
        mail_on_success: {{ True if mail_on_success else '' }}

{% for identifier in identifiers %}
/opt/rsync/bin/rsync-database.sh "{{ identifier }}" |& logger -t backups:
  cron.present:
    - identifier: rsync-{{ identifier }}
    - user: root
    - hour: 2
    - minute: random
{% endfor %}
