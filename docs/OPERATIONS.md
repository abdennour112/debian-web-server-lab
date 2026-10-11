# Operations guide

## Inspect services

```bash
systemctl status nginx lab-app named fail2ban ssh --no-pager
sudo nginx -t
sudo named-checkconf
sudo named-checkzone lab.test /etc/bind/db.lab.test
sudo ufw status verbose
sudo fail2ban-client status sshd
```

## Verify web and DNS functions inside Debian

```bash
curl --cacert /etc/nginx/tls/lab.crt \
  --resolve web.lab.test:443:127.0.0.1 https://web.lab.test/api/health
dig @127.0.0.1 web.lab.test
dig +tcp @127.0.0.1 web.lab.test
```

The API should return JSON with `status: ok`. The authoritative lab zone returns loopback addresses because its intended clients run on the VM.

## Read logs

```bash
sudo journalctl -u nginx -u lab-app -u named --since '-1 hour' --no-pager
sudo journalctl -u ssh --since '-1 hour' --no-pager
sudo tail -n 30 /var/log/nginx/lab.access.log
sudo tail -n 30 /var/log/nginx/lab.error.log
sudo journalctl -t lab-backup --since today --no-pager
```

BIND may log unsuccessful IPv6 root-key queries when the VM lacks IPv6 internet connectivity. The authoritative UDP/TCP lab-zone checks passed despite those messages. Investigate service failures separately from harmless connectivity messages.

## Backups

```bash
sudo /usr/local/sbin/lab-backup
sudo ls -lh /var/backups/lab
sudo cat /etc/cron.d/lab-backup
timedatectl
```

Cron runs at 02:15 in the VM's timezone. Check `timedatectl` rather than assuming the Windows timezone. Backup archives include server private keys; do not upload them to the public repository. This initial lab keeps archives without automatic pruning; monitor disk usage and add retention/off-machine encrypted storage before production use.

For a restore drill, use a separate root-only directory, check the checksum, extract, and compare files. Never extract over the running system until you have a reviewed recovery plan. The verification script performs this non-destructive drill for selected configuration and application files.

## Safely change configuration

Run syntax checks before reloading services. Preserve a working SSH session when changing firewall or SSH rules. The dedicated automation key works; password SSH remains enabled for your current Windows access. Root SSH is disabled. Use a unique account password and keep it out of documentation.

## Reboot verification (pending)

After a planned reboot, rerun the verification script and compare service status. All services are enabled, but a post-provisioning reboot has not yet been tested.

## Scope of the provisioning script

`scripts/provision.sh` configures a dedicated new lab. It replaces the default Nginx enabled site and BIND options/local zone files. It is not a migration script for an existing production server. It does not reset existing UFW rules, create the administrator account, install an SSH user key, issue a public TLS certificate, publish GitHub content or configure Windows DNS.
