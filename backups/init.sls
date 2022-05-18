{% from 'backups/map.jinja' import backup_root, mail_on_success, mail_to, mail_from with context %}

{$backup_root}:
  file.directory:
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

/opt/backups/bin:
  file.directory:
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

{# Create the database dump script, but do not mark it as executable #}
/opt/backups/bin/dump-database.sh:
  file.managed:
    - user: root
    - group: root
    - mode: 640
    - source: salt://backups/files/dump-database.sh
    - template: jinja
    - context:
        backup_root: {{ backup_root }}
        mail_to: {{ mail_to }}
        mail_from: {{ mail_from }}
        mail_on_success: {{ "True" if mail_on_success else '' }}
    - require:
      - file: /opt/backups/bin

/opt/backups/lib:
  file.directory:
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

{# Create a database configuration script for each database host in the pillar #}
{% for identifier, data in salt['pillar.get']('backups:database:hosts', {}).items() %}
/opt/backups/lib/{{ identifier }}.sh:
  file.managed:
    - user: root
    - group: root
    - mode: 640
    - source: salt://backups/files/{{ data.type }}.lib.sh
    - template: jinja
    - context:
        host: {{ data.host }}
        port: {{ data.port }}
        user: {{ data.get('user', '') }}
    - require:
      - file: /opt/backups/lib
{% endfor %}
