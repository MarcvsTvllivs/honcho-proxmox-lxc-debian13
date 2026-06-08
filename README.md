# Honcho Proxmox LXC Installer

This repo contains a Proxmox-host installer and maintenance helper for creating a dedicated Honcho LXC on Debian 13.

## Install

Run this on the **Proxmox host as root**.

### Community-scripts-style one-liner

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/honcho-proxmox-lxc-debian13/main/install.sh)"
```

This is convenient, but it executes the mutable `main` branch as root. For a more cautious Proxmox-host workflow, use download-then-run, inspect the script, or pin the raw URL to a reviewed commit/tag.

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
- a verified non-empty Postgres `pg_dumpall` dump
- git/service metadata

Backups contain secrets from `.env`; the helper creates the host backup directory with restrictive permissions and sets the tarball to mode `600`.

By default, backup fails closed if the database dump fails. If you intentionally want a config-only/partial archive, use:

```bash
./honcho-proxmox-lxc-debian13.sh backup --ctid 606 --allow-partial-backup
```

### Update Honcho safely

```bash
./honcho-proxmox-lxc-debian13.sh update --ctid 606
```

The update flow is intentionally conservative:

1. start the container if needed
2. verify the CTID looks like a Honcho LXC created by this installer
3. create a Proxmox snapshot named `pre-honcho-update-<timestamp>`
4. create a logical backup under `/root/honcho-backups`
5. fetch/update the Honcho git checkout, refusing to proceed if tracked local changes exist
6. re-apply LAN API binding if upstream compose is localhost-only
7. pull/build Docker Compose services
8. stop the API service before running Alembic migrations
9. restart `honcho.service`
10. fail the update if the post-update health check fails
11. prune unused Docker images after health passes
12. print status/health output

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
- The Honcho app update command intentionally does **not** run `apt upgrade`; OS package maintenance should be a separate maintenance window with its own snapshot/backup/reboot plan.

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
