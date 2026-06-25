#!/usr/bin/env bash
set -Eeuo pipefail

# Honcho Proxmox LXC installer
# Independent install and update script; not an official Honcho or Proxmox project.
# - prefers Debian 13 (Trixie)
# - auto-detects sensible Proxmox defaults when possible
# - installs Honcho via Docker Compose in its own LXC
# - enables Honcho auth by default when exposing the API on the LXC network
#
# Run this on the Proxmox host as root.

usage() {
  cat <<'EOF'
Usage:
  honcho-proxmox-lxc-debian13.sh install [options]
  honcho-proxmox-lxc-debian13.sh status --ctid ID
  honcho-proxmox-lxc-debian13.sh backup --ctid ID [--backup-dir DIR] [--allow-partial-backup]
  honcho-proxmox-lxc-debian13.sh update --ctid ID [--honcho-ref REF] [--no-snapshot] [--no-backup] [--yes]

With no subcommand, an interactive menu asks whether to install, update, show status,
or create a backup. In non-interactive use, install is assumed for backward compatibility.

Creates and maintains a dedicated Proxmox LXC for Honcho. Install creates the
LXC, installs Docker, clones Honcho, and starts it under systemd. Status, backup,
and update operate on an existing Honcho LXC.

Defaults:
  - Debian 13 template (requires a Debian 13 template in pveam)
  - unprivileged container
  - nesting/keyctl enabled for Docker-in-LXC
  - IPv4 via DHCP; IPv6 disabled inside the container after creation

Install options:
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
  --auth                    Enable Honcho auth (default; JWT secret generated)
  --no-auth                 Disable Honcho auth (trusted LAN only)
  --no-start                Create the LXC but do not start Honcho, so you can
                            edit /opt/honcho/.env before the first start
  --yes                     Skip confirmation prompt; requires --ctid (and an OpenAI key env var unless --no-start)
  --dry-run                 Print planned actions without changing anything

Provider key environment variables for install:
  HONCHO_LLM_OPENAI_API_KEY / LLM_OPENAI_API_KEY (required to start; optional with --no-start)
  HONCHO_LLM_ANTHROPIC_API_KEY / LLM_ANTHROPIC_API_KEY (optional)
  HONCHO_LLM_GEMINI_API_KEY / LLM_GEMINI_API_KEY (optional)

Maintenance options:
  --ctid ID                 Existing Honcho container ID
  --backup-dir DIR          Host-side backup directory (default: /root/honcho-backups)
  --no-snapshot             Do not create a Proxmox snapshot before update
  --no-backup               Do not run a logical backup before update
  --allow-partial-backup     Let backup succeed even if the DB dump fails
  --yes                     Skip maintenance confirmation prompts
  -h, --help                Show this help

After creation, the script prints the Honcho URL and, when auth is enabled,
an admin JWT. Configure your Honcho client/integration to use that URL and JWT.
EOF
}

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Guard a value-taking flag: pass the remaining args ("$@") so $# reflects how
# many are left. Dies with a friendly message instead of a set -u crash when the
# flag is the last token and its value is missing.
require_arg() { [[ $# -ge 2 ]] || die "Option '$1' requires a value."; }

rand_password() {
  if have openssl; then
    openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24
  else
    # head closing the pipe early would SIGPIPE tr (exit 141) and trip pipefail.
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true
  fi
}

create_admin_jwt() {
  # Mints a Honcho admin token: HS256 over the AUTH_JWT_SECRET with Honcho's
  # compact admin claims ({"t":"","ad":true}). Mirrors upstream Honcho's auth
  # scheme; if Honcho changes its JWT claim format this must be updated to match.
  local secret="$1"
  python3 - "$secret" <<'PY'
import base64
import hashlib
import hmac
import json
import sys

secret = sys.argv[1].encode("utf-8")

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")

header = {"alg": "HS256", "typ": "JWT"}
payload = {"t": "", "ad": True}
header_b64 = b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
payload_b64 = b64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
sig = hmac.new(secret, signing_input, hashlib.sha256).digest()
print(f"{header_b64}.{payload_b64}.{b64url(sig)}")
PY
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
  if pveam list "$storage" 2>/dev/null | awk '{print $1}' | grep -Fq "$template"; then
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

require_ref_safe() {
  local ref="$1"
  [[ -n "$ref" ]] || die "Honcho ref must not be empty."
  [[ "$ref" != -* ]] || die "Honcho ref must not start with '-'."
  [[ "$ref" =~ ^[A-Za-z0-9._/@+-]+$ ]] || die "Honcho ref contains unsupported characters. Use letters, numbers, '.', '_', '/', '@', '+', or '-'."
}

require_honcho_container() {
  local ctid="$1"
  ensure_ct_exists "$ctid"
  pct exec "$ctid" -- bash -lc '[[ -d /opt/honcho/.git && -x /usr/local/bin/honcho-compose && -f /etc/systemd/system/honcho.service ]]' \
    || die "Container $ctid does not look like a Honcho LXC created by this installer."
}

strict_health_check() {
  local ctid="$1"
  pct exec "$ctid" -- bash -lc 'set -euo pipefail
cd /opt/honcho
systemctl is-active --quiet honcho.service
/usr/local/bin/honcho-compose ps
curl -fsS http://127.0.0.1:8000/health >/dev/null
'
}

ensure_modern_compose_in_ct() {
  local ctid="$1"
  # Install the Docker Compose v2 CLI plugin only if the distro package didn't
  # already provide `docker compose`. Pull the latest release rather than pinning
  # a version, so this never points at a release tag that doesn't exist.
  pct exec "$ctid" -- bash -lc 'set -euo pipefail
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) asset="docker-compose-linux-x86_64" ;;
  aarch64|arm64) asset="docker-compose-linux-aarch64" ;;
  *) echo "Unsupported architecture for Docker Compose standalone binary: $arch" >&2; exit 1 ;;
esac
if docker compose version >/dev/null 2>&1; then
  exit 0
fi
url="https://github.com/docker/compose/releases/latest/download/${asset}"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "$url" -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
docker compose version >/dev/null
'
}

ensure_buildx_in_ct() {
  local ctid="$1"
  # Honcho api/deriver images are built from source, and modern Docker Compose
  # delegates the build to buildx (requires buildx >= 0.17.0). Debian's docker.io
  # does not ship a new-enough buildx, so install the latest plugin when needed.
  pct exec "$ctid" -- bash -lc 'set -euo pipefail
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) bx_arch=amd64 ;;
  aarch64|arm64) bx_arch=arm64 ;;
  *) echo "Unsupported architecture for buildx: $arch" >&2; exit 1 ;;
esac
have_new=0
ver="$(docker buildx version 2>/dev/null | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" | head -1 || true)"
ver="${ver#v}"
if [ -n "$ver" ] && [ "$(printf "%s\n0.17.0\n" "$ver" | sort -V | head -1)" = "0.17.0" ]; then
  have_new=1
fi
if [ "$have_new" = "0" ]; then
  url="$(curl -fsSLI -o /dev/null -w "%{url_effective}" https://github.com/docker/buildx/releases/latest)"
  tag="${url##*/tag/}"
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL "https://github.com/docker/buildx/releases/download/${tag}/buildx-${tag}.linux-${bx_arch}" -o /usr/local/lib/docker/cli-plugins/docker-buildx
  chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
fi
docker buildx version >/dev/null
'
}

INSTALL_CREATED_CTID=""
install_cleanup_on_error() {
  local ec=$?
  trap - ERR
  if [[ -n "$INSTALL_CREATED_CTID" ]]; then
    warn "Install failed (exit code $ec)."
    warn "A partially-configured container was left behind: CTID $INSTALL_CREATED_CTID"
    warn "Inspect it with:  pct config $INSTALL_CREATED_CTID"
    warn "Remove it with:   pct stop $INSTALL_CREATED_CTID && pct destroy $INSTALL_CREATED_CTID"
  fi
}

install_main() {
  local CTID=""
  local CT_HOSTNAME="honcho"
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
  local ANTHROPIC_KEY="${HONCHO_LLM_ANTHROPIC_API_KEY:-${LLM_ANTHROPIC_API_KEY:-}}"
  local OPENAI_KEY="${HONCHO_LLM_OPENAI_API_KEY:-${LLM_OPENAI_API_KEY:-}}"
  local GEMINI_KEY="${HONCHO_LLM_GEMINI_API_KEY:-${LLM_GEMINI_API_KEY:-}}"
  local ENABLE_AUTH="true"
  local AUTO_START="true"
  local YES="false"
  local DRY_RUN="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctid) require_arg "$@"; CTID="$2"; shift 2 ;;
      --hostname) require_arg "$@"; CT_HOSTNAME="$2"; shift 2 ;;
      --bridge) require_arg "$@"; BRIDGE="$2"; shift 2 ;;
      --storage) require_arg "$@"; ROOTFS_STORAGE="$2"; shift 2 ;;
      --tmpl-storage) require_arg "$@"; TMPL_STORAGE="$2"; shift 2 ;;
      --ip) require_arg "$@"; IPMODE="$2"; shift 2 ;;
      --gw) require_arg "$@"; GW="$2"; shift 2 ;;
      --vlan) require_arg "$@"; VLAN_TAG="$2"; shift 2 ;;
      --cores) require_arg "$@"; CORES="$2"; shift 2 ;;
      --memory) require_arg "$@"; MEMORY="$2"; shift 2 ;;
      --swap) require_arg "$@"; SWAP="$2"; shift 2 ;;
      --disk) require_arg "$@"; DISK="$2"; shift 2 ;;
      --password) require_arg "$@"; PASSWORD="$2"; shift 2 ;;
      --ssh-pubkey) require_arg "$@"; SSH_PUBKEY_FILE="$2"; shift 2 ;;
      --honcho-repo) require_arg "$@"; HONCHO_REPO="$2"; shift 2 ;;
      --honcho-ref) require_arg "$@"; HONCHO_REF="$2"; shift 2 ;;
      --auth) ENABLE_AUTH="true"; shift ;;
      --no-auth) ENABLE_AUTH="false"; shift ;;
      --no-start) AUTO_START="false"; shift ;;
      --yes) YES="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  require_ref_safe "$HONCHO_REF"

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
  [[ "$CORES" =~ ^[0-9]+$ ]]  || die "--cores must be a positive integer."
  [[ "$MEMORY" =~ ^[0-9]+$ ]] || die "--memory must be a positive integer (MB)."
  [[ "$SWAP" =~ ^[0-9]+$ ]]   || die "--swap must be a positive integer (MB)."
  [[ "$DISK" =~ ^[0-9]+$ ]]   || die "--disk must be a positive integer (GB)."

  local DETECTED_BRIDGE DETECTED_ROOTFS_STORAGE DETECTED_TMPL_STORAGE
  DETECTED_BRIDGE="$(auto_bridge)"
  DETECTED_ROOTFS_STORAGE="$(auto_root_storage)"
  DETECTED_TMPL_STORAGE="$(auto_tmpl_storage)"

  if [[ "$YES" == true ]]; then
    BRIDGE="${BRIDGE:-$DETECTED_BRIDGE}"
    ROOTFS_STORAGE="${ROOTFS_STORAGE:-$DETECTED_ROOTFS_STORAGE}"
    TMPL_STORAGE="${TMPL_STORAGE:-$DETECTED_TMPL_STORAGE}"
    PASSWORD="${PASSWORD:-$(rand_password)}"
  else
    prompt_default BRIDGE "Bridge" "${BRIDGE:-$DETECTED_BRIDGE}"
    prompt_default ROOTFS_STORAGE "Rootfs storage" "${ROOTFS_STORAGE:-$DETECTED_ROOTFS_STORAGE}"
    prompt_default TMPL_STORAGE "Template storage" "${TMPL_STORAGE:-$DETECTED_TMPL_STORAGE}"
    prompt_secret_default PASSWORD "Root password" "${PASSWORD:-$(rand_password)}"
  fi

  if [[ -f "$SSH_PUBKEY_FILE" ]]; then
    :
  elif [[ -n "$SSH_PUBKEY_FILE" ]]; then
    die "SSH public key file not found: $SSH_PUBKEY_FILE"
  fi

  local TEMPLATE
  TEMPLATE="$(auto_template)"

  if [[ "$ENABLE_AUTH" == true ]]; then
    have python3 || die "python3 is required to generate a Honcho admin JWT when auth is enabled."
  fi

  # Decide auto-start first: whether an OpenAI key is required now depends on it.
  if [[ "$YES" != true ]]; then
    local start_ans=""
    read -rp "Start Honcho now? Choose 'n' to edit /opt/honcho/.env before first start [Y/n]: " start_ans
    [[ "$start_ans" =~ ^[Nn] ]] && AUTO_START="false"
  fi

  # Honcho's default config needs an OpenAI-compatible key to *start*. Require it
  # only when auto-starting; with --no-start the user can add it to .env before
  # the first start, so it is optional here.
  if [[ "$DRY_RUN" != true && "$AUTO_START" == true && -z "$OPENAI_KEY" ]]; then
    if [[ "$YES" == true ]]; then
      die "HONCHO_LLM_OPENAI_API_KEY or LLM_OPENAI_API_KEY is required with --yes (Honcho's default config needs it to start). Use --no-start to install without starting and add the key to .env later."
    fi
    warn "No OpenAI-compatible API key provided. Honcho's default config requires LLM_OPENAI_API_KEY to start."
    read -rsp "OpenAI-compatible API key (required to start): " OPENAI_KEY; printf '\n' || true
    [[ -n "$OPENAI_KEY" ]] || die "An OpenAI-compatible API key is required to start Honcho. Re-run with --no-start to install without it and add the key to .env later."
  elif [[ "$DRY_RUN" != true && -z "$OPENAI_KEY" ]]; then
    if [[ "$YES" != true ]]; then
      read -rsp "OpenAI-compatible API key (optional now; add to .env before starting): " OPENAI_KEY; printf '\n' || true
    fi
    [[ -n "$OPENAI_KEY" ]] || warn "No OpenAI key set. Add LLM_OPENAI_API_KEY to /opt/honcho/.env before starting Honcho, or it will fail to start."
  fi
  if [[ "$DRY_RUN" != true && -z "$ANTHROPIC_KEY" ]]; then
    read -rsp "Anthropic API key (optional): " ANTHROPIC_KEY; printf '\n' || true
  fi
  if [[ "$DRY_RUN" != true && -z "$GEMINI_KEY" ]]; then
    read -rsp "Gemini API key (optional): " GEMINI_KEY; printf '\n' || true
  fi

  log "Detected/selected defaults"
  printf '  CTID:             %s\n' "$CTID"
  printf '  Hostname:         %s\n' "$CT_HOSTNAME"
  printf '  Bridge:           %s\n' "$BRIDGE"
  printf '  Root storage:     %s\n' "$ROOTFS_STORAGE"
  printf '  Template storage:  %s\n' "$TMPL_STORAGE"
  printf '  Template:         %s\n' "$TEMPLATE"
  printf '  IP mode:          %s\n' "$IPMODE"
  printf '  Cores/RAM/SWAP:   %s / %sMB / %sMB\n' "$CORES" "$MEMORY" "$SWAP"
  printf '  Disk:             %sGB\n' "$DISK"
  printf '  Auth:             %s\n' "$ENABLE_AUTH"
  printf '  Auto-start:       %s\n' "$AUTO_START"

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
    NETCFG="name=eth0,bridge=${BRIDGE},ip=dhcp"
  else
    [[ -n "$GW" ]] || die "Static IP mode requires --gw"
    NETCFG="name=eth0,bridge=${BRIDGE},ip=${IPMODE},gw=${GW}"
  fi
  if [[ -n "$VLAN_TAG" ]]; then
    NETCFG+=",tag=${VLAN_TAG}"
  fi

  local FEATURES="nesting=1,keyctl=1"
  local CREATE_ARGS=(
    create "$CTID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}"
    --hostname "$CT_HOSTNAME"
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

  trap install_cleanup_on_error ERR
  log "Creating container $CTID"
  pct "${CREATE_ARGS[@]}"
  INSTALL_CREATED_CTID="$CTID"

  log "Starting container $CTID"
  pct start "$CTID"

  log "Disabling IPv6 inside the container"
  pct exec "$CTID" -- bash -lc 'cat >/etc/sysctl.d/99-disable-ipv6.conf <<"EOF"
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true'

  log "Installing Docker + dependencies in the container"
  pct exec "$CTID" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y ca-certificates curl git gnupg lsb-release docker.io'
  log "Installing modern Docker Compose in the container"
  ensure_modern_compose_in_ct "$CTID"
  log "Ensuring buildx is available for building Honcho images"
  ensure_buildx_in_ct "$CTID"
  pct exec "$CTID" -- bash -lc 'cat >/usr/local/bin/honcho-compose <<"EOF"
#!/usr/bin/env bash
set -euo pipefail
if docker compose version >/dev/null 2>&1; then
  exec docker compose "$@"
elif command -v docker-compose >/dev/null 2>&1; then
  exec docker-compose "$@"
fi
echo "Docker Compose is not available" >&2
exit 1
EOF
chmod +x /usr/local/bin/honcho-compose'
  pct exec "$CTID" -- bash -lc 'systemctl enable --now docker'

  log "Cloning Honcho"
  pct exec "$CTID" -- bash -lc 'set -euo pipefail
ref="$1"
repo="$2"
mkdir -p /opt
if [[ ! -d /opt/honcho/.git ]]; then
  if ! git clone --branch "$ref" --depth 1 -- "$repo" /opt/honcho 2>/dev/null; then
    # git clone --branch only accepts a branch or tag name; fall back so a raw
    # commit SHA also works, matching the refs accepted by the update command.
    rm -rf /opt/honcho
    git init -q /opt/honcho
    git -C /opt/honcho remote add origin "$repo"
    git -C /opt/honcho fetch --depth 1 origin "$ref"
    git -C /opt/honcho checkout --detach FETCH_HEAD
  fi
else
  cd /opt/honcho
  git fetch --depth 1 origin "$ref"
  git checkout --detach FETCH_HEAD
fi
cd /opt/honcho
cp -f docker-compose.yml.example docker-compose.yml
python3 - <<'"'"'PY'"'"'
from pathlib import Path
path = Path("/opt/honcho/docker-compose.yml")
text = path.read_text()
repls = {
    "127.0.0.1:8000:8000": "0.0.0.0:8000:8000",
    "localhost:8000:8000": "0.0.0.0:8000:8000",
}
new_text = text
for old, new in repls.items():
    new_text = new_text.replace(old, new)
if new_text != text:
    path.write_text(new_text)
elif "0.0.0.0:8000:8000" not in new_text:
    raise SystemExit("Could not find a Honcho API port mapping for 8000 to expose on the LAN in docker-compose.yml")
PY
cp -f .env.template .env
' bash "$HONCHO_REF" "$HONCHO_REPO"

  local AUTH_JWT_SECRET=""
  local HONCHO_ADMIN_JWT=""
  if [[ "$ENABLE_AUTH" == true ]]; then
    AUTH_JWT_SECRET="$(rand_password)$(rand_password)"
    HONCHO_ADMIN_JWT="$(create_admin_jwt "$AUTH_JWT_SECRET")"
  fi

  local ENV_APPEND
  ENV_APPEND=$'\n# Added by honcho-proxmox-lxc-debian13.sh\nSENTRY_ENABLED=false\nAUTH_USE_AUTH='"$ENABLE_AUTH"$'\n'
  if [[ "$ENABLE_AUTH" == true ]]; then
    ENV_APPEND+=$'AUTH_JWT_SECRET='"$AUTH_JWT_SECRET"$'\n'
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
ExecStart=/usr/local/bin/honcho-compose up -d
ExecStop=/usr/local/bin/honcho-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable honcho.service
'

  if [[ "$AUTO_START" == true ]]; then
    log "Starting Honcho"
    pct exec "$CTID" -- bash -lc 'systemctl restart honcho.service'
    log "Waiting for Honcho to become healthy"
    local i HEALTHY="false"
    for ((i = 0; i < 30; i++)); do
      if pct exec "$CTID" -- bash -lc 'curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1'; then
        HEALTHY="true"; break
      fi
      sleep 5
    done
    if [[ "$HEALTHY" != true ]]; then
      warn "Honcho did not pass a health check within the timeout, but the container was created."
      warn "Check 'systemctl status honcho.service' and '/usr/local/bin/honcho-compose logs' inside CT $CTID."
    fi
  else
    log "Honcho installed but not started (you chose to edit .env first)."
  fi
  trap - ERR

  local CT_IP
  CT_IP="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
  [[ -n "$CT_IP" ]] || CT_IP="<container-ip>"

  if [[ "$AUTO_START" != true ]]; then
    cat <<EOF

Honcho LXC created but NOT started.

Container ID:      $CTID
URL (after start): http://$CT_IP:8000
Auth:              $ENABLE_AUTH

Next steps:
  1. Edit config:   pct exec $CTID -- nano /opt/honcho/.env
  2. Start Honcho:  pct exec $CTID -- systemctl start honcho.service
  3. Check health:  pct exec $CTID -- curl -fsS http://127.0.0.1:8000/health
EOF
    if [[ "$ENABLE_AUTH" == true ]]; then
      cat <<EOF

Admin JWT: $HONCHO_ADMIN_JWT

This token matches the AUTH_JWT_SECRET already written to .env. If you change
that secret while editing, regenerate the token after starting with:
  pct exec $CTID -- bash -lc 'cd /opt/honcho && /usr/local/bin/honcho-compose run --rm --entrypoint /app/.venv/bin/python api scripts/generate_jwt.py --admin --print-only'
EOF
    fi
    printf '\n'
  elif [[ "$ENABLE_AUTH" == true ]]; then
    cat <<EOF

Honcho LXC is up.

Container ID: $CTID
URL:          http://$CT_IP:8000
Auth:         enabled
Admin JWT:    $HONCHO_ADMIN_JWT

Save the Admin JWT somewhere secure. It is shown only at install time and is
needed by clients when connecting to an authenticated local Honcho.

Client setup:
  1. Configure your Honcho client or integration for local/self-hosted Honcho
  2. Point it at: http://$CT_IP:8000
  3. Use the Admin JWT as the bearer token / API token

EOF
  else
    cat <<EOF

Honcho LXC is up.

Container ID: $CTID
URL:          http://$CT_IP:8000
Auth:         disabled

WARNING: Auth is disabled. Keep this API on a trusted private network only.

Client setup:
  1. Configure your Honcho client or integration for local/self-hosted Honcho
  2. Point it at: http://$CT_IP:8000
  3. Leave the bearer token / API token unset

EOF
  fi
}


ensure_ct_exists() {
  local ctid="$1"
  [[ "$ctid" =~ ^[0-9]+$ ]] || die "CTID must be numeric."
  pct status "$ctid" >/dev/null 2>&1 || die "Container $ctid does not exist."
}

ensure_ct_running() {
  local ctid="$1"
  ensure_ct_exists "$ctid"
  if ! pct status "$ctid" | grep -q 'status: running'; then
    log "Starting container $ctid"
    pct start "$ctid"
  fi
}

compose_exec() {
  local ctid="$1"; shift
  pct exec "$ctid" -- bash -lc 'cd /opt/honcho && /usr/local/bin/honcho-compose "$@"' bash "$@"
}

parse_existing_ctid_args() {
  CTID=""
  BACKUP_DIR="/root/honcho-backups"
  HONCHO_REF="main"
  YES="false"
  MAKE_SNAPSHOT="true"
  MAKE_BACKUP="true"
  ALLOW_PARTIAL_BACKUP="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctid) require_arg "$@"; CTID="$2"; shift 2 ;;
      --backup-dir) require_arg "$@"; BACKUP_DIR="$2"; shift 2 ;;
      --honcho-ref) require_arg "$@"; HONCHO_REF="$2"; shift 2 ;;
      --yes) YES="true"; shift ;;
      --no-snapshot) MAKE_SNAPSHOT="false"; shift ;;
      --no-backup) MAKE_BACKUP="false"; shift ;;
      --allow-partial-backup) ALLOW_PARTIAL_BACKUP="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
  if [[ -z "$CTID" ]]; then
    if [[ "$YES" == true ]]; then
      die "Please provide --ctid when using --yes."
    fi
    if [[ -t 0 ]]; then
      read -rp "Existing Honcho LXC CTID: " CTID
    fi
  fi
  [[ -n "$CTID" ]] || die "Please provide --ctid for maintenance commands."
}

status_main() {
  local CTID BACKUP_DIR HONCHO_REF YES MAKE_SNAPSHOT MAKE_BACKUP ALLOW_PARTIAL_BACKUP
  parse_existing_ctid_args "$@"
  require_ref_safe "$HONCHO_REF"

  need_root
  have pct || die "pct not found. Are you on the Proxmox host?"
  ensure_ct_running "$CTID"

  log "Proxmox container status"
  pct status "$CTID"
  pct config "$CTID" | sed -n '1,80p'

  log "Honcho service status"
  pct exec "$CTID" -- bash -lc 'systemctl --no-pager --full status honcho.service || true'

  log "Docker Compose status"
  pct exec "$CTID" -- bash -lc 'cd /opt/honcho && /usr/local/bin/honcho-compose ps || true'

  log "Honcho git version"
  pct exec "$CTID" -- bash -lc 'cd /opt/honcho && git status --short && git log -1 --oneline || true'

  log "Local health checks"
  pct exec "$CTID" -- bash -lc 'curl -fsS http://127.0.0.1:8000/health 2>/dev/null || curl -fsSI http://127.0.0.1:8000 2>/dev/null || true'

  local CT_IP
  CT_IP="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
  [[ -n "$CT_IP" ]] && printf '\nHoncho URL from other LXCs: http://%s:8000\n' "$CT_IP"
}

backup_main() {
  local CTID BACKUP_DIR HONCHO_REF YES MAKE_SNAPSHOT MAKE_BACKUP ALLOW_PARTIAL_BACKUP
  parse_existing_ctid_args "$@"
  require_ref_safe "$HONCHO_REF"

  need_root
  have pct || die "pct not found. Are you on the Proxmox host?"
  ensure_ct_running "$CTID"
  require_honcho_container "$CTID"

  local stamp host_dir ct_dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  host_dir="${BACKUP_DIR%/}/ct-${CTID}-${stamp}"
  ct_dir="/root/honcho-backups/${stamp}"
  log "Creating backup directory $host_dir"
  umask 077
  mkdir -p "$host_dir"
  chmod 700 "$host_dir"

  log "Copying Honcho config files"
  pct exec "$CTID" -- bash -lc 'set -euo pipefail
ct_dir="$1"
mkdir -p "$ct_dir"
cp -a /opt/honcho/.env /opt/honcho/docker-compose.yml "$ct_dir"/
' bash "$ct_dir"

  log "Dumping Postgres from Compose database service"
  if ! pct exec "$CTID" -- bash -lc 'set -euo pipefail
ct_dir="$1"
cd /opt/honcho
DB_SERVICE=$(/usr/local/bin/honcho-compose config --services | grep -E "^(database|postgres|db|postgresql)$" | head -1 || true)
if [[ -z "$DB_SERVICE" ]]; then echo "No database service found" >&2; exit 2; fi
/usr/local/bin/honcho-compose exec -T "$DB_SERVICE" sh -c "pg_dumpall -U \"\${POSTGRES_USER:-postgres}\"" > "$ct_dir/postgres.sql"
test -s "$ct_dir/postgres.sql"
grep -Eq "PostgreSQL database dump|CREATE ROLE|CREATE DATABASE" "$ct_dir/postgres.sql"
' bash "$ct_dir"; then
    if [[ "$ALLOW_PARTIAL_BACKUP" == true ]]; then
      warn "Database dump failed. Continuing because --allow-partial-backup was provided."
      pct exec "$CTID" -- bash -lc 'ct_dir="$1"; touch "$ct_dir/PARTIAL_BACKUP_DB_DUMP_FAILED"' bash "$ct_dir" || true
    else
      die "Database dump failed; refusing to create a backup that looks complete. Re-run with --allow-partial-backup only if you accept this."
    fi
  fi

  log "Capturing service metadata"
  pct exec "$CTID" -- bash -lc 'set -euo pipefail
ct_dir="$1"
cd /opt/honcho
{ git log -1 --oneline || true; git status --short || true; /usr/local/bin/honcho-compose ps || true; } > "$ct_dir/metadata.txt"
' bash "$ct_dir"

  log "Pulling backup archive to Proxmox host"
  pct exec "$CTID" -- bash -lc 'set -euo pipefail
stamp="$1"
cd /root/honcho-backups
tar -czf "${stamp}.tar.gz" "$stamp"
' bash "$stamp"
  pct pull "$CTID" "/root/honcho-backups/${stamp}.tar.gz" "$host_dir/honcho-backup.tar.gz"
  chmod 600 "$host_dir/honcho-backup.tar.gz"
  pct exec "$CTID" -- bash -lc 'ct_dir="$1"; stamp="$2"; rm -rf -- "$ct_dir" "/root/honcho-backups/${stamp}.tar.gz"' bash "$ct_dir" "$stamp"

  log "Backup complete: $host_dir/honcho-backup.tar.gz"
}

update_main() {
  local CTID BACKUP_DIR HONCHO_REF YES MAKE_SNAPSHOT MAKE_BACKUP ALLOW_PARTIAL_BACKUP
  parse_existing_ctid_args "$@"
  require_ref_safe "$HONCHO_REF"

  need_root
  have pct || die "pct not found. Are you on the Proxmox host?"
  have pvesm || warn "pvesm not found; continuing because pct snapshots may still work."
  ensure_ct_running "$CTID"
  require_honcho_container "$CTID"

  if [[ "$YES" != true ]]; then
    cat <<EOF
This will update Honcho inside CT $CTID.

Planned safety steps:
  Proxmox snapshot: $MAKE_SNAPSHOT
  Logical backup:   $MAKE_BACKUP
  Honcho ref:       $HONCHO_REF

EOF
    confirm "Proceed with Honcho update?" || die "Aborted."
  fi

  if [[ "$MAKE_SNAPSHOT" == true ]]; then
    local snap
    snap="pre-honcho-update-$(date +%Y%m%d-%H%M%S)"
    log "Creating Proxmox snapshot $snap"
    pct snapshot "$CTID" "$snap" || die "Snapshot failed. Re-run with --no-snapshot only if you intentionally accept that risk."
  fi

  if [[ "$MAKE_BACKUP" == true ]]; then
    backup_main --ctid "$CTID" --backup-dir "$BACKUP_DIR" --yes
  fi

  log "Updating Honcho git checkout"
  pct exec "$CTID" -- bash -lc 'set -euo pipefail
ref="$1"
cd /opt/honcho
printf "Before: "; git log -1 --oneline || true
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  git status --short
  echo "Refusing to update with local tracked changes in /opt/honcho." >&2
  exit 3
fi
# The install uses a shallow, single-branch clone, so origin/$ref and the
# objects behind $ref may not exist locally. Fetch the requested ref explicitly
# and act on FETCH_HEAD, which works for branches and tags at any clone depth.
git fetch --depth 1 origin "$ref"
if git ls-remote --exit-code --heads origin "$ref" >/dev/null 2>&1; then
  git checkout -B "$ref" FETCH_HEAD
else
  git checkout --detach FETCH_HEAD
fi
printf "After:  "; git log -1 --oneline || true
' bash "$HONCHO_REF"

  log "Ensuring modern Docker Compose is available"
  ensure_modern_compose_in_ct "$CTID"
  log "Ensuring buildx is available for building Honcho images"
  ensure_buildx_in_ct "$CTID"

  log "Refreshing docker-compose.yml from upstream example"
  pct exec "$CTID" -- bash -lc 'set -euo pipefail
cd /opt/honcho
if [[ -f docker-compose.yml.example ]]; then
  cp -f docker-compose.yml.example docker-compose.yml
fi
'

  log "Re-applying LAN API port mapping if docker-compose.yml uses localhost only"
  pct exec "$CTID" -- bash -lc "python3 - <<'PY'
from pathlib import Path
path = Path('/opt/honcho/docker-compose.yml')
if not path.exists():
    raise SystemExit(0)
text = path.read_text()
repls = {
    '127.0.0.1:8000:8000': '0.0.0.0:8000:8000',
    'localhost:8000:8000': '0.0.0.0:8000:8000',
}
for old, new in repls.items():
    text = text.replace(old, new)
path.write_text(text)
PY"

  log "Rebuilding/pulling containers"
  pct exec "$CTID" -- bash -lc "set -euo pipefail
cd /opt/honcho
/usr/local/bin/honcho-compose pull || true
/usr/local/bin/honcho-compose build --pull
"

  log "Running database migrations"
  pct exec "$CTID" -- bash -lc 'set -euo pipefail
cd /opt/honcho
API_SERVICE=$(/usr/local/bin/honcho-compose config --services | grep -E "^(api|server|honcho|web)$" | head -1 || true)
if [[ -z "$API_SERVICE" ]]; then API_SERVICE=api; fi
/usr/local/bin/honcho-compose stop "$API_SERVICE" || true
# The api image entrypoint (sh docker/entrypoint.sh) always runs migrations and
# then starts the server, ignoring any command passed to it - so a plain
# "compose run ... <cmd>" never returns and the update hangs. Override the
# entrypoint to run only the migration (scripts/provision_db.py, the very step
# the entrypoint runs) so it migrates and exits.
/usr/local/bin/honcho-compose run --rm --entrypoint /app/.venv/bin/python "$API_SERVICE" scripts/provision_db.py
'

  log "Restarting Honcho"
  pct exec "$CTID" -- bash -lc 'systemctl daemon-reload && systemctl restart honcho.service'

  log "Verifying Honcho health after update"
  strict_health_check "$CTID" || die "Honcho did not pass post-update health checks. Snapshot/backup were created; inspect logs before retrying."

  log "Pruning unused Docker images"
  pct exec "$CTID" -- bash -lc 'docker image prune -f >/dev/null || true'

  status_main --ctid "$CTID" --yes
}

choose_command() {
  local choice
  cat >&2 <<'EOF'
Honcho Proxmox LXC

What do you want to do?
  1) Install a new Honcho LXC
  2) Update an existing Honcho LXC
  3) Show status for an existing Honcho LXC
  4) Create a backup for an existing Honcho LXC
  q) Quit
EOF
  while true; do
    read -rp "Select an option [1-4/q]: " choice
    case "$choice" in
      1|install|Install) printf 'install'; return 0 ;;
      2|update|Update) printf 'update'; return 0 ;;
      3|status|Status) printf 'status'; return 0 ;;
      4|backup|Backup) printf 'backup'; return 0 ;;
      q|Q|quit|Quit|exit|Exit) exit 0 ;;
      *) warn "Please choose 1, 2, 3, 4, or q." ;;
    esac
  done
}

main() {
  local cmd=""
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|status|backup|update) cmd="$1"; shift ;;
      -h|--help) usage; return 0 ;;
      *) cmd="install" ;;
    esac
  fi

  if [[ -z "$cmd" ]]; then
    if [[ -t 0 && -t 1 ]]; then
      cmd="$(choose_command)"
    else
      cmd="install"
    fi
  fi

  case "$cmd" in
    install) install_main "$@" ;;
    status) status_main "$@" ;;
    backup) backup_main "$@" ;;
    update) update_main "$@" ;;
  esac
}

main "$@"
