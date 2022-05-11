# Set a grain
{% if grains.get('smallstep', False) %}
roles:
  grains.append:
    - value: rsync

install_sshpass:
  pkg:
    - name: sshpass
    - installed
    - enablerepo: epel

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

## Copy ID to rsync.net
#rsync_copy_id:
#  cmd.run:
#    - name: |
#        echo '{{ pillar['rsync']['pass'] }}' | sshpass ssh-copy-id /root/.ssh/rsync_id.pub rsyncbackup && touch /root/.ssh/.rsync-copied
#    - creates: /root/.ssh/.rsync-copied
#    - require: 
#      - pkg: sshpass

# Add our paths from pillar
{% for path in pillar['rsync']['paths'] %}
rsync-{{path}}:
  file.managed:
    - name: /etc/rsync-backup.txt
    - text: {{ path }}
{% endfor %}

# rsync / db dump script
/opt/rsync/bin:
  file.directory:
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

/opt/rsync/bin/rsync-backup.sh:
  file.managed:
    - user: root
    - group: root
    - mode: 750
    - source: salt://rsyncnet/files/rsync-backup.sh
    - require:
      - file: /opt/rsync/bin

# cron entry to run script
#  Enable DB dumps if rsync:dumpdbs is True. Set a default False value if doesn't exist
{% set dumpdbs = salt['pillar.get']('rsync:dumpdbs', False) %}
{% if dumpdbs == True %}
/opt/rsync/bin/rsync-backup.sh dumpdbs 2>&1 | logger -t backups:
  cron.present:
    - identifier: rsyncbackup
    - user: root
    - minute: random
    - hour: 2
{% elif 'mysql' in salt['grains.get']('roles', 'roles:none') %}
/opt/rsync/bin/rsync-backup.sh dumpdbs 2>&1 | logger -t backups:
  cron.present:
    - identifier: rsyncbackup
    - user: root
    - minute: random
    - hour: 2
{% else %}
/opt/rsync/bin/rsync-backup.sh 2>&1 | logger -t backups:
  cron.present:
    - identifier: rsyncbackup
    - user: root
    - minute: random
    - hour: 2
{% endif %}
