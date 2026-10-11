#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get install -y nginx ufw openssl python3 bind9 bind9-utils dnsutils fail2ban python3-systemd cron curl git
install -d -m 755 /opt/lab-app /var/www/lab /etc/nginx/tls
id labapp >/dev/null 2>&1 || useradd --system --home /opt/lab-app --shell /usr/sbin/nologin labapp
cat > /opt/lab-app/app.py <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/health':
            self.send_error(404)
            return
        body = json.dumps({'status': 'ok', 'service': 'lab-app', 'via': 'nginx reverse proxy'}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
ThreadingHTTPServer(('127.0.0.1', 8000), Handler).serve_forever()
PY
cat > /etc/systemd/system/lab-app.service <<'UNIT'
[Unit]
Description=Lab Python health API
After=network.target
[Service]
User=labapp
Group=labapp
WorkingDirectory=/opt/lab-app
ExecStart=/usr/bin/python3 -u /opt/lab-app/app.py
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6
[Install]
WantedBy=multi-user.target
UNIT
cat > /var/www/lab/index.html <<'HTML'
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Debian Web Server Lab</title><style>body{margin:0;background:#102033;color:#edf3fa;font:18px system-ui}main{max-width:850px;margin:12vh auto;padding:35px}h1{font-size:48px}p{line-height:1.6}a{color:#72ddc5}.tag{color:#72ddc5;text-transform:uppercase;letter-spacing:3px}code{background:#23384c;padding:5px;border-radius:5px}</style><main><p class="tag">Linux infrastructure portfolio</p><h1>Debian Web Server Lab</h1><p>A working lab for Nginx, TLS, DNS, reverse proxying, service isolation, firewall rules and recoverable backups.</p><p>Built on Debian 13. HTTPS uses a self-signed lab certificate.</p><p><a href="/api/health">Check the Python backend</a></p><p>Backend listens only on <code>127.0.0.1:8000</code>. Public entry points are SSH, HTTP and HTTPS.</p></main></html>
HTML
if [ ! -f /etc/nginx/tls/lab.key ]; then
  openssl req -x509 -nodes -newkey rsa:3072 -days 365 -keyout /etc/nginx/tls/lab.key -out /etc/nginx/tls/lab.crt -subj '/CN=web.lab.test' -addext 'subjectAltName=DNS:web.lab.test,DNS:lab.test'
fi
chmod 600 /etc/nginx/tls/lab.key
touch /var/log/nginx/lab.access.log /var/log/nginx/lab.error.log
chown root:adm /var/log/nginx/lab.access.log /var/log/nginx/lab.error.log
chmod 640 /var/log/nginx/lab.access.log /var/log/nginx/lab.error.log
cat > /etc/nginx/sites-available/lab <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name web.lab.test lab.test;
    return 301 https://web.lab.test$request_uri;
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name web.lab.test lab.test;
    ssl_certificate /etc/nginx/tls/lab.crt;
    ssl_certificate_key /etc/nginx/tls/lab.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    root /var/www/lab;
    index index.html;
    access_log /var/log/nginx/lab.access.log;
    error_log /var/log/nginx/lab.error.log;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    location / { try_files $uri $uri/ =404; }
    location /api/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 15s;
    }
}
NGINX
if [ -L /etc/nginx/sites-enabled/default ]; then unlink /etc/nginx/sites-enabled/default; fi
ln -sfn /etc/nginx/sites-available/lab /etc/nginx/sites-enabled/lab
cat > /etc/bind/named.conf.options <<'BIND'
options {
    directory "/var/cache/bind";
    listen-on { 127.0.0.1; };
    listen-on-v6 { ::1; };
    recursion no;
    allow-query { localhost; };
    allow-transfer { none; };
    dnssec-validation auto;
};
BIND
cat > /etc/bind/named.conf.local <<'ZONE'
zone "lab.test" {
    type primary;
    file "/etc/bind/db.lab.test";
};
ZONE
cat > /etc/bind/db.lab.test <<'DNS'
$TTL 300
@ IN SOA ns.lab.test. admin.lab.test. (2026101101 3600 900 604800 300)
@ IN NS ns.lab.test.
@ IN A 127.0.0.1
ns IN A 127.0.0.1
web IN A 127.0.0.1
DNS
cat > /etc/fail2ban/jail.d/lab-sshd.local <<'JAIL'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
banaction = ufw
JAIL
cat > /usr/local/sbin/lab-backup <<'BACKUP'
#!/bin/bash
set -euo pipefail
umask 077
install -d -m 700 /var/backups/lab
archive="/var/backups/lab/lab-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -czf "$archive" -C / etc/nginx etc/bind etc/fail2ban etc/ufw etc/ssh etc/systemd/system/lab-app.service etc/cron.d/lab-backup opt/lab-app var/www/lab usr/local/sbin/lab-backup
sha256sum "$archive" > "$archive.sha256"
logger -t lab-backup "Created $archive"
echo "$archive"
BACKUP
chmod 750 /usr/local/sbin/lab-backup
cat > /etc/cron.d/lab-backup <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 2 * * * root /usr/local/sbin/lab-backup >> /var/log/lab-backup.log 2>&1
CRON
cat > /etc/ssh/sshd_config.d/00-lab.conf <<'SSH'
PermitRootLogin no
PubkeyAuthentication yes
Compression no
DisableForwarding yes
X11Forwarding no
PermitTunnel no
MaxAuthTries 3
LoginGraceTime 30
SSH
sshd -t
nginx -t
named-checkconf
named-checkzone lab.test /etc/bind/db.lab.test
systemctl daemon-reload
systemctl enable --now lab-app nginx named fail2ban cron
systemctl restart lab-app nginx named fail2ban
systemctl reload ssh
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo '=== Validation ==='
systemctl is-active ssh nginx named lab-app fail2ban cron
ufw status verbose
curl --fail --silent --show-error --cacert /etc/nginx/tls/lab.crt --resolve web.lab.test:443:127.0.0.1 https://web.lab.test/api/health
echo
dig @127.0.0.1 web.lab.test +short
fail2ban-client status sshd
archive=$(/usr/local/sbin/lab-backup)
sha256sum -c "$archive.sha256"
restore=$(mktemp -d /var/backups/lab/restore-test.XXXXXX)
tar -xzf "$archive" -C "$restore"
cmp /var/www/lab/index.html "$restore/var/www/lab/index.html"
cmp /opt/lab-app/app.py "$restore/opt/lab-app/app.py"
echo "Restore verified in $restore"
ss -lntup
echo 'Provisioning and validation complete'
