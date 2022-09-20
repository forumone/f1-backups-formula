{% from 'backups/map.jinja' import backup_root, mail_on_success, mail_from, mail_to with context %}

{% set rsync_host = salt['pillar.get']('backups:rsync:host', 'rsyncbackup') %}
{% set rsync_paths = salt['pillar.get']('backups:rsync:paths', ['/etc', '/srv']) %}
{% set rsync_from_snapshot = salt['pillar.get']('backups:rsync:from_snapshot', True) %}

{% set all_db_identifiers = salt['pillar.get']('backups:database:hosts', {}).keys() %}
{% set identifiers = salt['pillar.get']('backups:rsync:databases', all_db_identifiers) %}

# Ensure dir exists and perms are correct
/root/.ssh:
  file.directory:
    - user: root
    - group: root
    - mode: 700

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
        user: {{ salt['pillar.get']('backups:rsync:user') }}

#verify rsync.net fingerprint is in the known_hosts file
usw-s007.rsync.net:
  ssh_known_hosts:
    - present
    - user: root
    - fingerprint: G4hq1a+D2he0uy43fYYFp3F3FXiSFmVFdJiwQYb/UzQ
    - fingerprint_hash_type: sha256
      
#verify github's fingerprint is in the known_hosts as well
github.com:
  ssh_known_hosts:
    - present
    - user: root
    - fingerprint: 16:27:ac:a5:76:28:2d:36:63:1b:56:4d:eb:df:a6:48
    - fingerprint_hash_type: md5


# Copy ID to rsync.net
# temporary, run this manually
# scp /root/.ssh/rsync_id.pub rsyncbackup:.ssh/authorized_keys

# Add our paths from pillar
/etc/rsync-backup.txt:
  file.managed:
    - user: root
    - group: root
    - mode: '0600'
    - contents: {{ rsync_paths | join("\n") | yaml_encode }}

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
        rsync_payload: /etc/rsync-backup.txt
        rsync_from_snapshot: {{ "True" if rsync_from_snapshot else '' | yaml_encode }}
        mail_to: {{ mail_to }}
        mail_from: {{ mail_from }}
        mail_on_success: {{ "True" if mail_on_success else '' | yaml_encode }}
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
        backup_root: {{ backup_root }}
        rsync_host: {{ rsync_host }}
        mail_to: {{ mail_to }}
        mail_from: {{ mail_from }}
        mail_on_success: {{ "True" if mail_on_success else '' | yaml_encode }}

{% for identifier in identifiers %}
/opt/rsync/bin/rsync-database.sh "{{ identifier }}" |& logger -t backups:
  cron.present:
    - identifier: rsync-{{ identifier }}
    - user: root
    - hour: 2
    - minute: random
{% endfor %}
