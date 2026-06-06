# Honcho Proxmox LXC Installer

This repo contains a Proxmox-host installer for creating a dedicated Honcho LXC on Debian 13.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/honcho-proxmox-lxc-debian13/main/honcho-proxmox-lxc-debian13.sh -o honcho-proxmox-lxc-debian13.sh
chmod +x honcho-proxmox-lxc-debian13.sh
sudo ./honcho-proxmox-lxc-debian13.sh
```

## Notes

- The script prompts interactively for API keys when needed.
- Do not pass secrets on the command line if you can avoid it.
