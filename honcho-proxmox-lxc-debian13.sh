#!/usr/bin/env bash
set -Eeuo pipefail

# Honcho Proxmox LXC installer
# - prefers Debian 13 (Trixie)
# - auto-detects sensible Proxmox defaults when possible
# - installs Honcho via Docker Compose in its own LXC
#
# Run this on the Proxmox host as root.

usage() {
  cat <<'EOF'
Usage:
  honcho-proxmox-lxc-debian13.sh [options]

Creates a dedicated Proxmox LXC for Honcho, installs Docker, clones Honcho,
and starts it under systemd.

Defaults:
  - Debian 13 template (requires a Debian 13 template in pveam)
  - unprivileged container
  - nesting/keyctl enabled for Docker-in-LXC
  - IPv4 via DHCP, IPv6 disabled (ip6=none)

Options:
  --ctid ID                 Container ID to create (required unless prompted)
  --hostname NAME           Container hostname (default: honcho)
  --bridge NAME             Proxmox bridge (default: auto-detect)
  --storage NAME            Rootfs storage (default: auto-detect)
  --tmpl-storage NAME       Template storage (default: auto-detect)
  --ip ADDR[/CIDR]|dhcp     Static IP or dhcp (default: dhcp)
  --gw IP                   Gateway when using static IP
  --vlan TAG                Optional VLAN tag
  --cores N                 vCPU count (default: 2)
  --memory MB               RAM in MB (default: 4096)
  --swap MB                 Swap in MB (default: 1024)
  --disk GB                 Root disk size in GB (default: 32)
  --password PASS           Root password (default: generated)
  --ssh-pubkey FILE         Install SSH public key
  --honcho-repo URL         Honcho repo URL (default: upstream Honcho)
  --honcho-ref REF          Git ref/branch/tag (default: main)
  --auth                    Enable Honcho auth (JWT secret generated)
  --no-auth                 Disable Honcho auth (default)
  --yes                     Skip confirmation prompt
  --dry-run                 Print planned actions without changing anything
  -h, --help                Show this help

After creation, the script prints the Honcho URL. In Hermes, run:
  hermes memory setup

Then choose Honcho and point it at that URL.
EOF
}

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

rand_password() {
  if have openssl; then
    openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  fi
}

auto_bridge() {
  local b
  b="$(ip -o link show type bridge 2>/dev/null | awk -F': ' 'NR==1{print $2}')"
  if [[ -n "$b" ]]; then
    printf '%s' "$b"
  else
    printf 'vmbr0'
  fi
}

auto_tmpl_storage() {
  local storages
  storages="$(pvesm status 2>/dev/null | awk 'NR>1 {print $1}')"
  if grep -qx 'local' <<<"$storages"; then
    printf 'local'
    return 0
  fi
  local s
  s="$(awk 'NF{print; exit}' <<<"$storages")"
  if [[ -n "$s" ]]; then
    printf '%s' "$s"
  else
    printf 'local'
  fi
}

auto_root_storage() {
  local storages
  storages="$(pvesm status 2>/dev/null | awk 'NR>1 {print $1}')"
  if grep -qx 'local-lvm' <<<"$storages"; then
    printf 'local-lvm'
    return 0
  fi
  local s
  s="$(awk 'NF{print; exit}' <<<"$storages")"
  if [[ -n "$s" ]]; then
    printf '%s' "$s"
  else
    printf 'local-lvm'
  fi
}

auto_template() {
  local tmpl
  tmpl="$(pveam available --section system 2>/dev/null | awk '/debian-13-standard_/ {print $2; exit}')"
  if [[ -n "$tmpl" ]]; then
    printf '%s' "$tmpl"
    return 0
  fi
  die "No Debian 13 template found in pveam. Run: pveam update"
}

ensure_template() {
  local storage="$1"
  local template="$2"
  pveam update >/dev/null
  if pveam list "$storage" 2>/dev/null | awk '{print $1}' | grep -q "$template"; then
    return 0
  fi
  log "Downloading template $template into storage $storage"
  pveam download "$storage" "$template"
}

confirm() {
  local answer
  read -rp "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

prompt_default() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local value=""
  read -rp "$prompt [$default_value]: " value
  if [[ -z "$value" ]]; then
    value="$default_value"
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_secret_default() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local value=""
  read -rsp "$prompt [leave blank to use generated]: " value
  printf '\n'
  if [[ -z "$value" ]]; then
    value="$default_value"
  fi
  printf -v "$var_name" '%s' "$value"
}

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this on the Proxmox host as root."
}

main() {
  local CTID=""
  local HOSTNAME="honcho"
  local BRIDGE=""
  local ROOTFS_STORAGE=""
  local TMPL_STORAGE=""
  local IPMODE="dhcp"
  local GW=""
  local VLAN_TAG=""
  local CORES="2"
  local MEMORY="4096"
  local SWAP="1024"
  local DISK="32"
  local PASSWORD=""
  local SSH_PUBKEY_FILE=""
  local HONCHO_REPO="https://github.com/plastic-labs/honcho.git"
  local HONCHO_REF="main"
  local ANTHROPIC_KEY=""
  local OPENAI_KEY=""
  local GEMINI_KEY=""
  local ENABLE_AUTH="false"
  local YES="false"
  local DRY_RUN="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctid) CTID="$2"; shift 2 ;;
      --hostname) HOSTNAME="$2"; shift 2 ;;
      --bridge) BRIDGE="$2"; shift 2 ;;
      --storage) ROOTFS_STORAGE="$2"; shift 2 ;;
      --tmpl-storage) TMPL_STORAGE="$2"; shift 2 ;;
      --ip) IPMODE="$2"; shift 2 ;;
      --gw) GW="$2"; shift 2 ;;
      --vlan) VLAN_TAG="$2"; shift 2 ;;
      --cores) CORES="$2"; shift 2 ;;
      --memory) MEMORY="$2"; shift 2 ;;
      --swap) SWAP="$2"; shift 2 ;;
      --disk) DISK="$2"; shift 2 ;;
      --password) PASSWORD="$2"; shift 2 ;;
      --ssh-pubkey) SSH_PUBKEY_FILE="$2"; shift 2 ;;
      --honcho-repo) HONCHO_REPO="$2"; shift 2 ;;
      --honcho-ref) HONCHO_REF="$2"; shift 2 ;;
      --auth) ENABLE_AUTH="true"; shift ;;
      --no-auth) ENABLE_AUTH="false"; shift ;;
      --yes) YES="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  need_root
  have pct || die "pct not found. Are you on the Proxmox host?"
  have pveam || die "pveam not found. Proxmox tools are missing."
  have pvesm || die "pvesm not found. Proxmox tools are missing."

  if [[ -z "$CTID" ]]; then
    if [[ "$YES" == true ]]; then
      die "Please provide --ctid when using --yes."
    fi
    read -rp "Container ID to create: " CTID
  fi
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID must be numeric."
  if pct list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CTID"; then
    die "CTID $CTID is already in use."
  fi

  local DETECTED_BRIDGE DETECTED_ROOTFS_STORAGE DETECTED_TMPL_STORAGE
  DETECTED_BRIDGE="$(auto_bridge)"
  DETECTED_ROOTFS_STORAGE="$(auto_root_storage)"
  DETECTED_TMPL_STORAGE="$(auto_tmpl_storage)"

  if [[ "$YES" == true ]]; then
    BRIDGE="$DETECTED_BRIDGE"
    ROOTFS_STORAGE="$DETECTED_ROOTFS_STORAGE"
    TMPL_STORAGE="$DETECTED_TMPL_STORAGE"
    PASSWORD="$(rand_password)"
  else
    prompt_default BRIDGE "Bridge" "$DETECTED_BRIDGE"
    prompt_default ROOTFS_STORAGE "Rootfs storage" "$DETECTED_ROOTFS_STORAGE"
    prompt_default TMPL_STORAGE "Template storage" "$DETECTED_TMPL_STORAGE"
    prompt_secret_default PASSWORD "Root password" "$(rand_password)"
  fi

  if [[ -f "$SSH_PUBKEY_FILE" ]]; then
    :
  elif [[ -n "$SSH_PUBKEY_FILE" ]]; then
    die "SSH public key file not found: $SSH_PUBKEY_FILE"
  fi

  local TEMPLATE
  TEMPLATE="$(auto_template)"

  if [[ "$DRY_RUN" != true && -z "$ANTHROPIC_KEY$OPENAI_KEY$GEMINI_KEY" ]]; then
    warn "No LLM API key provided. Honcho needs at least one provider key."
    read -rsp "Anthropic API key (optional): " ANTHROPIC_KEY; printf '\n' || true
    read -rsp "OpenAI API key (optional): " OPENAI_KEY; printf '\n' || true
    read -rsp "Gemini API key (optional): " GEMINI_KEY; printf '\n' || true
  fi
  if [[ "$DRY_RUN" != true && -z "$ANTHROPIC_KEY$OPENAI_KEY$GEMINI_KEY" ]]; then
    die "At least one LLM API key is required."
  fi

  log "Detected/selected defaults"
  printf '  CTID:             %s\n' "$CTID"
  printf '  Hostname:         %s\n' "$HOSTNAME"
  printf '  Bridge:           %s\n' "$BRIDGE"
  printf '  Root storage:     %s\n' "$ROOTFS_STORAGE"
  printf '  Template storage:  %s\n' "$TMPL_STORAGE"
  printf '  Template:         %s\n' "$TEMPLATE"
  printf '  IP mode:          %s\n' "$IPMODE"
  printf '  Cores/RAM/SWAP:   %s / %sMB / %sMB\n' "$CORES" "$MEMORY" "$SWAP"
  printf '  Disk:             %sGB\n' "$DISK"
  printf '  Auth:             %s\n' "$ENABLE_AUTH"

  if [[ "$DRY_RUN" == true ]]; then
    log "Dry-run only; no changes will be made."
    return 0
  fi

  if [[ "$YES" != true ]]; then
    confirm "Proceed with LXC creation?" || die "Aborted."
  fi

  ensure_template "$TMPL_STORAGE" "$TEMPLATE"

  local NETCFG
  if [[ "$IPMODE" == dhcp ]]; then
    NETCFG="name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=none"
  else
    [[ -n "$GW" ]] || die "Static IP mode requires --gw"
    NETCFG="name=eth0,bridge=${BRIDGE},ip=${IPMODE},gw=${GW},ip6=none"
  fi
  if [[ -n "$VLAN_TAG" ]]; then
    NETCFG+=",tag=${VLAN_TAG}"
  fi

  local FEATURES="nesting=1,keyctl=1"
  local CREATE_ARGS=(
    create "$CTID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}"
    --hostname "$HOSTNAME"
    --ostype debian
    --unprivileged 1
    --features "$FEATURES"
    --onboot 1
    --startup "order=20,up=20"
    --cores "$CORES"
    --memory "$MEMORY"
    --swap "$SWAP"
    --rootfs "${ROOTFS_STORAGE}:${DISK}"
    --net0 "$NETCFG"
    --password "$PASSWORD"
  )
  if [[ -f "$SSH_PUBKEY_FILE" ]]; then
    CREATE_ARGS+=(--ssh-public-keys "$SSH_PUBKEY_FILE")
  fi

  log "Creating container $CTID"
  pct "${CREATE_ARGS[@]}"

  log "Starting container $CTID"
  pct start "$CTID"

  log "Installing Docker + dependencies in the container"
  pct exec "$CTID" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y ca-certificates curl git gnupg lsb-release docker.io docker-compose-plugin'
  pct exec "$CTID" -- bash -lc 'systemctl enable --now docker'

  log "Cloning Honcho"
  pct exec "$CTID" -- bash -lc "set -euo pipefail
mkdir -p /opt
if [[ ! -d /opt/honcho/.git ]]; then
  git clone --branch '$HONCHO_REF' --depth 1 '$HONCHO_REPO' /opt/honcho
else
  cd /opt/honcho
  git fetch --depth 1 origin '$HONCHO_REF'
  git checkout '$HONCHO_REF'
  git pull --ff-only
fi
cd /opt/honcho
cp -f docker-compose.yml.example docker-compose.yml
cp -f .env.template .env
"

  local ENV_APPEND
  ENV_APPEND=$'\n# Added by honcho-proxmox-lxc-debian13.sh\nSENTRY_ENABLED=false\nAUTH_USE_AUTH='"$ENABLE_AUTH"$'\n'
  if [[ "$ENABLE_AUTH" == true ]]; then
    ENV_APPEND+=$'AUTH_JWT_SECRET='"$(rand_password)$(rand_password)"$'\n'
  fi
  [[ -n "$ANTHROPIC_KEY" ]] && ENV_APPEND+=$'LLM_ANTHROPIC_API_KEY='"$ANTHROPIC_KEY"$'\n'
  [[ -n "$OPENAI_KEY" ]] && ENV_APPEND+=$'LLM_OPENAI_API_KEY='"$OPENAI_KEY"$'\n'
  [[ -n "$GEMINI_KEY" ]] && ENV_APPEND+=$'LLM_GEMINI_API_KEY='"$GEMINI_KEY"$'\n'
  pct exec "$CTID" -- bash -lc 'cat >> /opt/honcho/.env' <<<"$ENV_APPEND"

  if [[ -f "$SSH_PUBKEY_FILE" ]]; then
    log "Installing SSH public key"
    pct push "$CTID" "$SSH_PUBKEY_FILE" /root/.ssh/authorized_keys --create-dirs
  fi

  log "Creating Honcho systemd service"
  pct exec "$CTID" -- bash -lc 'cat >/etc/systemd/system/honcho.service <<"EOF"
[Unit]
Description=Honcho memory stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/honcho
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable honcho.service
systemctl restart honcho.service
'

  sleep 5
  local CT_IP
  CT_IP="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
  [[ -n "$CT_IP" ]] || CT_IP="<container-ip>"

  cat <<EOF

Honcho LXC is up.

Container ID: $CTID
URL:          http://$CT_IP:8000
Auth:         $ENABLE_AUTH

Hermes hookup:
  1. In the Hermes LXC run: hermes memory setup
  2. Choose Honcho
  3. Point it at: http://$CT_IP:8000

EOF
}

main "$@"
