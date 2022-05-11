/etc/rsync-backup.txt:
  file.managed:
    - user: root
    - group: root
    - mode: 750
    - source: salt://rsync/files/rsync-backup.txt
    - require:
      - file: /opt/rsync/bin

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
    - source: salt://rsync/files/rsync-backup.sh
    - require:
      - file: /opt/rsync/bin
