# Honcho Proxmox LXC Installer

Create and maintain a dedicated [Honcho](https://github.com/plastic-labs/honcho) LXC on a Proxmox VE host.

This repository provides a Bash installer/maintenance helper that:

- creates an unprivileged Debian 13 LXC for Honcho,
- enables the LXC features needed for Docker-in-LXC,
- installs Docker and a modern standalone Docker Compose binary inside the container,
- clones upstream Honcho and starts it via `honcho.service`,
- exposes the Honcho API on the container's LAN address on port `8000`,
- provides `status`, `backup`, and conservative `update` commands.

> This is an independent install and update script, not an official Honcho or Proxmox project.

## Requirements

Run the script on the **Proxmox host as root**. The host must have standard Proxmox tools available:

- `pct`
- `pveam`
- `pvesm`
- network access to GitHub and Debian/Proxmox package mirrors

The installer expects a Debian 13 LXC template to be available through `pveam`. If none is found, it fails closed and asks you to run `pveam update` rather than silently downgrading to another OS release.

## Security model

By default, the installer:

- creates an unprivileged LXC,
- binds the Honcho API to the container network interface (`0.0.0.0:8000` inside Docker Compose) so other LXCs can reach it,
- enables Honcho authentication and prints an admin JWT for client setup,
- stores Honcho provider API keys inside `/opt/honcho/.env` in the LXC,
- expects an OpenAI-compatible API key for the default upstream Honcho configuration, because the bundled defaults use OpenAI-compatible chat and embedding models.

Treat the printed Honcho admin JWT and the LXC's `/opt/honcho/.env` as secrets.

If you intentionally want a trusted-LAN/no-auth deployment, pass `--no-auth`. Do not expose a no-auth Honcho API to the public Internet.

## Defaults

| Setting | Default | Notes |
| --- | --- | --- |
| OS template | Debian 13 | Fails if unavailable |
| CTID | Prompted | Required with `--yes` |
| Hostname | `honcho` | Override with `--hostname` |
| Bridge | Auto-detected, fallback `vmbr0` | Prompted interactively |
| Rootfs storage | Auto-detected, prefers `local-lvm` | Prompted interactively |
| Template storage | Auto-detected, prefers `local` | Prompted interactively |
| Network | DHCP IPv4 | Static IP supported with `--ip` and `--gw` |
| IPv6 | Disabled inside the container | Not passed as a Proxmox `net0` option |
| Cores | `2` | Override with `--cores` |
| RAM | `4096` MB | Override with `--memory` |
| Swap | `1024` MB | Override with `--swap` |
| Disk | `32` GB | Override with `--disk` |
| LXC privilege | Unprivileged | Fixed by installer |
| LXC features | `nesting=1,keyctl=1` | Needed for Docker-in-LXC |
| Honcho ref | `main` | Override with `--honcho-ref` |
| Honcho auth | Enabled | Disable only with `--no-auth` |

## Install

### One-line installer

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

### Non-interactive install

`--yes` skips confirmation prompts but still requires enough information to avoid guessing important values. Provide at least `--ctid` and preseed an OpenAI-compatible provider key through the environment. Honcho's default self-host config uses OpenAI-compatible chat and embedding models:

```bash
export HONCHO_LLM_OPENAI_API_KEY='<openai-compatible-api-key>'
./honcho-proxmox-lxc-debian13.sh install --yes --ctid {CTID}
```

Supported key environment variables:

```text
HONCHO_LLM_OPENAI_API_KEY      # required for the default config
HONCHO_LLM_ANTHROPIC_API_KEY  # optional, for custom Honcho model routing
HONCHO_LLM_GEMINI_API_KEY     # optional, for custom Honcho model routing
```

The script also accepts upstream-style aliases if already set:

```text
LLM_OPENAI_API_KEY
LLM_ANTHROPIC_API_KEY
LLM_GEMINI_API_KEY
```

Avoid passing provider keys as command-line arguments because command lines can appear in shell history and process listings.

## Maintenance

Download the helper on the Proxmox host if you do not already have it:

```bash
curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/honcho-proxmox-lxc-debian13/main/honcho-proxmox-lxc-debian13.sh -o honcho-proxmox-lxc-debian13.sh
chmod +x honcho-proxmox-lxc-debian13.sh
```

Replace `{CTID}` below with your Honcho LXC container ID.

### Check status

```bash
./honcho-proxmox-lxc-debian13.sh status --ctid {CTID}
```

This checks:

- Proxmox container status/config,
- `honcho.service`,
- Docker Compose services,
- current Honcho git commit,
- local health endpoint,
- the Honcho URL to use from other LXCs.

### Create a backup

```bash
./honcho-proxmox-lxc-debian13.sh backup --ctid {CTID}
```

The backup is written on the Proxmox host under:

```text
/root/honcho-backups/ct-{CTID}-{timestamp}/honcho-backup.tar.gz
```

It includes:

- `/opt/honcho/.env`,
- `/opt/honcho/docker-compose.yml`,
- a verified non-empty Postgres `pg_dumpall` dump,
- git/service metadata.

Backups contain secrets from `.env`; the helper creates the host backup directory with restrictive permissions and sets the tarball to mode `600`.

By default, backup fails closed if the database dump fails. If you intentionally want a config-only/partial archive, use:

```bash
./honcho-proxmox-lxc-debian13.sh backup --ctid {CTID} --allow-partial-backup
```

### Update Honcho safely

```bash
./honcho-proxmox-lxc-debian13.sh update --ctid {CTID}
```

The update flow is intentionally conservative:

1. start the container if needed,
2. verify the CTID looks like a Honcho LXC created by this installer,
3. create a Proxmox snapshot named `pre-honcho-update-{timestamp}`,
4. create a logical backup under `/root/honcho-backups`,
5. fetch/update the Honcho git checkout, refusing to proceed if tracked local changes exist,
6. re-apply LAN API binding if upstream compose is localhost-only,
7. ensure a modern Docker Compose is available, refresh `docker-compose.yml` from upstream `docker-compose.yml.example`, then pull/build Docker Compose services,
8. stop the API service before running Alembic migrations,
9. restart `honcho.service`,
10. fail the update if the post-update health check fails,
11. prune unused Docker images after health passes,
12. print status/health output.

Useful flags:

```bash
./honcho-proxmox-lxc-debian13.sh update --ctid {CTID} --yes
./honcho-proxmox-lxc-debian13.sh update --ctid {CTID} --honcho-ref main
./honcho-proxmox-lxc-debian13.sh update --ctid {CTID} --backup-dir /root/honcho-backups
```

Only skip safety steps when you mean it:

```bash
./honcho-proxmox-lxc-debian13.sh update --ctid {CTID} --no-snapshot
./honcho-proxmox-lxc-debian13.sh update --ctid {CTID} --no-backup
```

## Client setup

After install/update, configure your Honcho client or integration to use the URL printed by the installer/status command, usually:

```text
http://<honcho-lxc-ip>:8000
```

If you kept the default authenticated deployment, use the printed Honcho admin JWT as the client's bearer token / API token. If you installed with `--no-auth`, leave the token unset and keep the API on a trusted private network only.

## Notes

- Run this on the Proxmox host as root.
- The install command prompts interactively for required values.
- CTID, bridge, rootfs storage, template storage, and root password are prompted unless supplied explicitly or generated.
- Honcho's API is exposed on the container network interface so other LXCs can reach it on port `8000`.
- IPv6 is disabled inside the container after creation; it is not passed as a `net0` option.
- Do not pass secrets on the command line if you can avoid it.
- Avoid unattended Honcho app updates; use the `update` command so snapshots, backups, compose refresh, migrations, and health checks happen in order.
- The Honcho app update command intentionally does **not** run `apt upgrade`; OS package maintenance should be a separate maintenance window with its own snapshot/backup/reboot plan.

## License

MIT License. See [LICENSE](LICENSE).
