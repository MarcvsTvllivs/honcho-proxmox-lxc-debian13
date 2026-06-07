# Honcho Proxmox LXC Installer

This repo contains a Proxmox-host installer and maintenance helper for creating a dedicated Honcho LXC on Debian 13.

## Install

Run this on the **Proxmox host as root**.

### Community-scripts-style one-liner

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/honcho-proxmox-lxc-debian13/main/install.sh)"
```

### Download-then-run

```bash
curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/honcho-proxmox-lxc-debian13/main/honcho-proxmox-lxc-debian13.sh -o honcho-proxmox-lxc-debian13.sh
chmod +x honcho-proxmox-lxc-debian13.sh
./honcho-proxmox-lxc-debian13.sh install
```

With no subcommand, `install` is assumed for backward compatibility:

```bash
./honcho-proxmox-lxc-debian13.sh
```

## Maintenance

Download the helper on the Proxmox host if you do not already have it:

```bash
curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/honcho-proxmox-lxc-debian13/main/honcho-proxmox-lxc-debian13.sh -o honcho-proxmox-lxc-debian13.sh
chmod +x honcho-proxmox-lxc-debian13.sh
```

Replace `606` below with your Honcho LXC CTID.

### Check status

```bash
./honcho-proxmox-lxc-debian13.sh status --ctid 606
```

This checks:

- Proxmox container status/config
- `honcho.service`
- Docker Compose services
- current Honcho git commit
- local health endpoint
- the Honcho URL to use from other LXCs

### Create a backup

```bash
./honcho-proxmox-lxc-debian13.sh backup --ctid 606
```

The backup is written on the Proxmox host under:

```text
/root/honcho-backups/ct-<CTID>-<timestamp>/honcho-backup.tar.gz
```

It includes:

- `/opt/honcho/.env`
- `/opt/honcho/docker-compose.yml`
- a Postgres `pg_dumpall` dump when the Compose database service can be found
- git/service metadata

### Update Honcho safely

```bash
./honcho-proxmox-lxc-debian13.sh update --ctid 606
```

The update flow is intentionally conservative:

1. start the container if needed
2. create a Proxmox snapshot named `pre-honcho-update-<timestamp>`
3. create a logical backup under `/root/honcho-backups`
4. fetch/update the Honcho git checkout
5. re-apply LAN API binding if upstream compose is localhost-only
6. pull/build Docker Compose services
7. run Alembic migrations
8. restart `honcho.service`
9. prune unused Docker images
10. print status/health output

Useful flags:

```bash
./honcho-proxmox-lxc-debian13.sh update --ctid 606 --yes
./honcho-proxmox-lxc-debian13.sh update --ctid 606 --honcho-ref main
./honcho-proxmox-lxc-debian13.sh update --ctid 606 --backup-dir /tank/backups/honcho
```

Only skip safety steps when you mean it:

```bash
./honcho-proxmox-lxc-debian13.sh update --ctid 606 --no-snapshot
./honcho-proxmox-lxc-debian13.sh update --ctid 606 --no-backup
```

## Notes

- Run this on the Proxmox host as root.
- The install command prompts interactively for required values.
- Honcho's API is exposed on the container network interface so other LXCs can reach it on port 8000.
- IPv6 is disabled inside the container after creation; it is not passed as a `net0` option.
- Do not pass secrets on the command line if you can avoid it.
- Avoid unattended Honcho app updates; use the `update` command so snapshots, backups, migrations, and health checks happen in order.

## Hermes hookup

After install/update, from the Hermes LXC run:

```bash
hermes memory setup honcho
hermes honcho status
```

Point Hermes at the URL printed by the installer/status command, usually:

```text
http://<honcho-lxc-ip>:8000
```
