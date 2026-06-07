#!/usr/bin/env bash
set -Eeuo pipefail

# Community-scripts-style bootstrapper.
# This file is meant to be fetched and evaluated with `bash -c "$(curl ...)"`
# so the interactive installer runs on a real terminal.

RAW_URL="https://raw.githubusercontent.com/MarcvsTvllivs/honcho-proxmox-lxc-debian13/main/honcho-proxmox-lxc-debian13.sh"
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

curl -fsSL "$RAW_URL" -o "$TMP_FILE"
chmod +x "$TMP_FILE"
exec "$TMP_FILE" "$@"
