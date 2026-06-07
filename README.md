# Honcho Proxmox LXC Installer

This repo contains a Proxmox-host installer for creating a dedicated Honcho LXC on Debian 13.

## Usage

### Community-scripts-style one-liner

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/honcho-proxmox-lxc-debian13/main/install.sh)"
```

### Download-then-run

```bash
curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/honcho-proxmox-lxc-debian13/main/honcho-proxmox-lxc-debian13.sh -o honcho-proxmox-lxc-debian13.sh
chmod +x honcho-proxmox-lxc-debian13.sh
./honcho-proxmox-lxc-debian13.sh
```

## Notes

- Run this on the Proxmox host as root.
- The script prompts interactively for any required values.
- Honcho's API is exposed on the container network interface so other LXCs can reach it on port 8000.
- IPv6 is disabled inside the container after creation; it is not passed as a `net0` option.
- Do not pass secrets on the command line if you can avoid it.
