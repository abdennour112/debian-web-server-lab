#!/bin/bash
set -euo pipefail
echo '=== UTC timestamp ==='
date -u --iso-8601=seconds
echo '=== OS and versions ==='
cat /etc/os-release
nginx -v
named -v
python3 --version
echo '=== Services ==='
for service in ssh nginx named lab-app fail2ban cron; do
  printf '%s: ' "$service"; systemctl is-active "$service"
  printf 'enabled: '; systemctl is-enabled "$service"
done
echo '=== Config validation ==='
nginx -t
sshd -t
named-checkconf
named-checkzone lab.test /etc/bind/db.lab.test
echo '=== Firewall ==='
ufw status verbose
echo '=== Static page and trusted TLS ==='
curl -fsS --cacert /etc/nginx/tls/lab.crt --resolve web.lab.test:443:127.0.0.1 https://web.lab.test/ | grep -o 'Debian Web Server Lab' | head -1
curl -fsS --cacert /etc/nginx/tls/lab.crt --resolve web.lab.test:443:127.0.0.1 https://web.lab.test/api/health
echo
echo '=== DNS UDP and TCP ==='
dig @127.0.0.1 web.lab.test +short
dig +tcp @127.0.0.1 web.lab.test +short
echo '=== fail2ban controlled action test ==='
trap 'fail2ban-client set sshd unbanip 192.0.2.123 >/dev/null 2>&1 || true' EXIT
fail2ban-client set sshd banip 192.0.2.123
fail2ban-client get sshd banip | grep 192.0.2.123
ufw status | grep 192.0.2.123
fail2ban-client set sshd unbanip 192.0.2.123
fail2ban-client status sshd
echo 'Manual ban/unban action verified; failed-login detection not simulated.'
echo '=== Backup and restore ==='
archive=$(/usr/local/sbin/lab-backup)
sha256sum -c "$archive.sha256"
restore=$(mktemp -d /var/backups/lab/restore-test.XXXXXX)
tar -xzf "$archive" -C "$restore"
for path in var/www/lab/index.html opt/lab-app/app.py etc/nginx/sites-available/lab etc/bind/db.lab.test; do
  cmp "/$path" "$restore/$path"
  echo "Restore content matches: $path"
done
echo '=== Scheduled backup ==='
cat /etc/cron.d/lab-backup
echo '=== Recent service log summary ==='
journalctl -u nginx -u named -u lab-app --since '-15 minutes' --no-pager | tail -12
echo '=== Nginx error log size ==='
wc -c /var/log/nginx/lab.error.log
echo '=== SSH effective settings ==='
sshd -T | grep -E '^(permitrootlogin|pubkeyauthentication|passwordauthentication) '
echo 'PASS: all verification commands completed'
