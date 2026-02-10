#!/usr/bin/env bash
#
# Hardened Home Assistant OS VM creator for Proxmox VE 8/9
#
# - Creates a Home Assistant OS VM using Proxmox CLI tools (qm, pvesm, pvesh)
# - Does NOT modify Proxmox networking, repositories, firewall, or system config
# - Uses HTTPS + metadata to find HAOS OVA URLs, no eval, no remote "source"
# - Uses a cache + integrity check for the downloaded .xz image
# - Optional USB passthrough (e.g. Zigbee/Z-Wave sticks) via qm set
#
# This matches:
# - Proxmox VE Host System Administration guidance: use qm/pvesm/pvesh for VM/storage operations.[page:0]
# - Home Assistant's recommendation to run Home Assistant OS as a dedicated system.[page:1]

# ---------- Header / banner ----------
function header_info {
  clear
  cat <<"EOF"
    __  __                        ___              _      __              __     ____  _____
   / / / /___  ____ ___  ___     /   |  __________(_)____/ /_____ _____  / /_   / __ \/ ___/
  / /_/ / __ \/ __ `__ \/ _ \   / /| | / ___/ ___/ / ___/ __/ __ `/ __ \/ __/  / / / /\__ \
 / __  / /_/ / / / / / /  __/  / ___ |(__  |__  ) (__  ) /_/ /_/ / / / / /_   / /_/ /___/ /
/_/ /_/\____/_/ /_/ /_/\___/  /_/  |_/____/____/_/____/\__/\__,_/_/ /_/\__/   \____//____/

EOF
}

header_info
echo -e "\n Loading..."

# ---------- Colors / UI ----------
YW="\033[33m"
BL="\033[36m"
RD="\033[01;31m"
BGN="\033[4;92m"
GN="\033[1;92m"
DGN="\033[32m"
CL="\033[m"
BFR="\r\033[K"
HOLD=" "
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

THIN="discard=on,ssd=1,"
SPINNER_PID=""
set -Eeuo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ---------- Error / cleanup ----------
function error_handler() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" > /dev/null 2>&1; then
    kill "$SPINNER_PID" > /dev/null 2>&1 || true
  fi
  printf "\e[?25h"
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function cleanup_vmid() {
  if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
    qm stop "$VMID" &>/dev/null || true
    qm destroy "$VMID" &>/dev/null || true
  fi
}

function cleanup() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" > /dev/null 2>&1; then
    kill "$SPINNER_PID" > /dev/null 2>&1 || true
  fi
  printf "\e[?25h"
  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
    popd >/dev/null 2>&1 || true
    rm -rf "$TEMP_DIR"
  fi
}

TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null

# ---------- Small helpers ----------
function spinner() {
  local chars="/-\|"
  local spin_i=0
  printf "\e[?25l"
  while true; do
    printf "\r \e[36m%s\e[0m" "${chars:spin_i++%${#chars}:1}"
    sleep 0.1
  done
}

function msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}   "
  spinner &
  SPINNER_PID=$!
}

function msg_ok() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" > /dev/null 2>&1; then
    kill "$SPINNER_PID" > /dev/null 2>&1 || true
  fi
  printf "\e[?25h"
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

function msg_error() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" > /dev/null 2>&1; then
    kill "$SPINNER_PID" > /dev/null 2>&1 || true
  fi
  printf "\e[?25h"
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

function exit-script() {
  clear
  echo -e "⚠  User exited script \n"
  exit 1
}

# ---------- Safety checks ----------
function check_root() {
  if [[ "$(id -u)" -ne 0 || "$(ps -o comm= -p "$PPID")" == "sudo" ]]; then
    clear
    msg_error "Please run this script as root (not via sudo)."
    echo -e "\nExiting..."
    sleep 2
    exit 1
  fi
}

# Proxmox VE 8.x (8.0–8.9) and 9.0–9.1.[page:0]
function pve_check() {
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"

  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    if (( MINOR < 0 || MINOR > 9 )); then
      msg_error "Unsupported Proxmox VE version: $PVE_VER"
      echo -e "Supported: Proxmox VE 8.0 – 8.9"
      exit 1
    fi
    return 0
  fi

  if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    if (( MINOR < 0 || MINOR > 1 )); then
      msg_error "Unsupported Proxmox VE version: $PVE_VER"
      echo -e "Supported: Proxmox VE 9.0 – 9.1"
      exit 1
    fi
    return 0
  fi

  msg_error "Unsupported Proxmox VE version: $PVE_VER"
  echo -e "Supported: Proxmox VE 8.0 – 8.9 or 9.0 – 9.1"
  exit 1
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    msg_error "This script requires amd64 Proxmox (no PiMox / ARM)."
    echo -e "Exiting..."
    sleep 2
    exit 1
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Script" --defaultno --title "SSH DETECTED" \
        --yesno "It's recommended to use the Proxmox node shell or console instead of SSH for interactive scripts. Proceed over SSH?" 10 70; then
        echo "you've been warned"
      else
        clear
        exit 1
      fi
    fi
  fi
}

# ---------- Utility: generate next free VMID ----------
function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

# ---------- HAOS version handling (no eval) ----------
# Primary metadata source (official version service), with GitHub fallback.
HA_STABLE_JSON_PRIMARY="https://version.home-assistant.io/stable.json"
HA_STABLE_JSON_FALLBACK="https://raw.githubusercontent.com/home-assistant/version/master/stable.json"
HA_BETA_JSON_PRIMARY="https://version.home-assistant.io/beta.json"
HA_BETA_JSON_FALLBACK="https://raw.githubusercontent.com/home-assistant/version/master/beta.json"
HA_DEV_JSON_PRIMARY="https://version.home-assistant.io/dev.json"
HA_DEV_JSON_FALLBACK="https://raw.githubusercontent.com/home-assistant/version/master/dev.json"

# Returns a version string like "17.0" from the JSON "ova" field.
function get_haos_ova_version() {
  local primary="$1"
  local fallback="$2"
  local json
  local ver

  json="$(curl -fsSL "$primary" 2>/dev/null || true)"
  [[ -z "$json" ]] && json="$(curl -fsSL "$fallback" 2>/dev/null || true)"
  [[ -z "$json" ]] && return 1

  ver="$(printf '%s\n' "$json" | grep '"ova"' | head -n1 | cut -d '"' -f 4)"
  # Sanity: version-ish (e.g. 17.0, 17.0.rc1, 17.0b1)
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+)+([a-z0-9.\-]+)?$ ]] || return 1

  printf '%s\n' "$ver"
}

msg_info "Retrieving Home Assistant OS version metadata"
STABLE_VER="$(get_haos_ova_version "$HA_STABLE_JSON_PRIMARY" "$HA_STABLE_JSON_FALLBACK")" || {
  msg_error "Unable to retrieve stable HAOS OVA version from metadata."
  echo "You can hard-code STABLE_VER (e.g., STABLE_VER=\"17.0\") if needed."
  exit 1
}
BETA_VER="$(get_haos_ova_version "$HA_BETA_JSON_PRIMARY" "$HA_BETA_JSON_FALLBACK" || true)"
DEV_VER="$(get_haos_ova_version "$HA_DEV_JSON_PRIMARY" "$HA_DEV_JSON_FALLBACK" || true)"
msg_ok "Retrieved HAOS versions (Stable: $STABLE_VER)"


# ---------- Image download helpers ----------
function ensure_pv() {
  if ! command -v pv &>/dev/null; then
    msg_info "Installing required package: pv"
    if ! apt-get update -qq &>/dev/null || ! apt-get install -y pv &>/dev/null; then
      msg_error "Failed to install pv automatically."
      echo -e "\nPlease run manually on the Proxmox host:\n  apt install pv\n"
      exit 1
    fi
    msg_ok "Installed pv"
  fi
}
function ensure_xz() {
  if ! command -v xz &>/dev/null; then
    msg_info "Installing required package: xz-utils"
    if ! apt-get update -qq &>/dev/null || ! apt-get install -y xz-utils &>/dev/null; then
      msg_error "Failed to install xz-utils automatically."
      echo -e "\nPlease run manually on the Proxmox host:\n  apt install xz-utils\n"
      exit 1
    fi
    msg_ok "Installed xz-utils"
  fi
}

function download_and_validate_xz() {
  local url="$1"
  local file="$2"

  if [[ -s "$file" ]]; then
    if xz -t "$file" &>/dev/null; then
      msg_ok "Using cached image $(basename "$file")"
      return 0
    else
      msg_error "Cached file $(basename "$file") is corrupted. Deleting..."
      rm -f "$file"
    fi
  fi

  msg_info "Downloading image: $(basename "$file")"
  # Stop spinner before curl so progress shows
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" > /dev/null 2>&1; then
    kill "$SPINNER_PID" > /dev/null 2>&1 || true
  fi
  printf "\e[?25h"
  
  if ! curl -fSL --progress-bar \
    --connect-timeout 10 --max-time 1800 \
    --retry 3 --retry-delay 2 --retry-all-errors \
    -o "$file" "$url"; then
    msg_error "Download failed: $url"
    rm -f "$file"
    exit 1
  fi
  echo ""

  if ! xz -t "$file" &>/dev/null; then
    msg_error "Downloaded file $(basename "$file") is corrupted."
    rm -f "$file"
    exit 1
  fi
  msg_ok "Downloaded and validated $(basename "$file")"
}

function extract_xz_with_pv() {
  set -o pipefail
  local file="$1"
  local target="$2"

  msg_info "Decompressing $(basename "$file") to $target"
  if ! xz -dc "$file" | pv -N "Extracting" >"$target"; then
    msg_error "Failed to extract $file"
    rm -f "$target"
    exit 1
  fi
  msg_ok "Decompressed to $target"
}

# ---------- Settings (default / advanced) ----------
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')

# Optional: USB passthrough config (host bus:device)
USB_PASSTHROUGH=""
USB_SLOT="0"

function default_settings() {
  BRANCH="stable"
  BRANCH_URL="$STABLE_VER"
  VMID="$(get_valid_nextid)"
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE="cache=writethrough,"
  DISK_SIZE="32G"
  HN="haos-stable"
  CPU_TYPE=" -cpu host"
  CORE_COUNT="2"
  RAM_SIZE="4096"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  USB_PASSTHROUGH=""
  USB_SLOT="0"

  echo -e "${DGN}HAOS Branch: ${BGN}${BRANCH}${CL}"
  echo -e "${DGN}HAOS Version: ${BGN}${BRANCH_VER}${CL}"
  echo -e "${DGN}VMID: ${BGN}${VMID}${CL}"
  echo -e "${DGN}Machine Type: ${BGN}i440fx${CL}"
  echo -e "${DGN}Disk Cache: ${BGN}Write Through${CL}"
  echo -e "${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${DGN}CPU Model: ${BGN}Host${CL}"
  echo -e "${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${DGN}RAM: ${BGN}${RAM_SIZE} MiB${CL}"
  echo -e "${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${DGN}MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${DGN}VLAN: ${BGN}Default${CL}"
  echo -e "${DGN}Interface MTU: ${BGN}Default${CL}"
  echo -e "${DGN}USB Passthrough: ${BGN}None${CL}"
  echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${BL}Creating a HAOS VM using the above default settings${CL}"
}

function advanced_settings() {
  if BRANCH=$(whiptail --backtitle "Proxmox VE Helper Script" --title "HAOS VERSION" \
    --radiolist "Choose Version" --cancel-button Exit-Script 10 58 3 \
    "stable" "Stable" ON \
    "beta"   "Beta"   OFF \
    "dev"    "Dev"    OFF \
    3>&1 1>&2 2>&3); then
        case "$BRANCH" in
      stable) BRANCH_VER="$STABLE_VER" ;;
      beta)   BRANCH_VER="$BETA_VER" ;;
      dev)    BRANCH_VER="$DEV_VER" ;;
    esac
    if [[ -z "$BRANCH_VER" ]]; then
      msg_error "No version available for selected branch: $BRANCH"
      exit 1
    fi
    echo -e "${DGN}HAOS Branch: ${BGN}$BRANCH${CL}"
    echo -e "${DGN}HAOS Version: ${BGN}${BRANCH_VER}${CL}"
  else
    exit-script
  fi

  local NEXTID
  NEXTID="$(get_valid_nextid)"

  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
      "Set Virtual Machine ID" 8 58 "$NEXTID" --title "VIRTUAL MACHINE ID" \
      --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$VMID" ]] && VMID="$NEXTID"
      if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
        echo -e "${CROSS}${RD} VMID must be numeric${CL}"
        sleep 2
        continue
      fi
      if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
        echo -e "${CROSS}${RD} ID $VMID is already in use${CL}"
        sleep 2
        continue
      fi
      echo -e "${DGN}VMID: ${BGN}$VMID${CL}"
      break
    else
      exit-script
    fi
  done

  if MACH=$(whiptail --backtitle "Proxmox VE Helper Script" --title "MACHINE TYPE" \
    --radiolist --cancel-button Exit-Script "Choose Type" 10 58 2 \
    "i440fx" "Machine i440fx" ON \
    "q35"    "Machine q35 (recommended for PCIe/USB passthrough)" OFF \
    3>&1 1>&2 2>&3); then
    if [ "$MACH" = "q35" ]; then
      echo -e "${DGN}Machine Type: ${BGN}$MACH${CL}"
      FORMAT=""
      MACHINE=" -machine q35"
    else
      echo -e "${DGN}Machine Type: ${BGN}$MACH${CL}"
      FORMAT=",efitype=4m"
      MACHINE=""
    fi
  else
    exit-script
  fi

  if DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
    "Set Disk Size in GiB (e.g., 32)" 8 58 32 --title "DISK SIZE" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    DISK_SIZE=$(echo "$DISK_SIZE" | tr -d ' ')
    if [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then
      DISK_SIZE="${DISK_SIZE}G"
    elif ! [[ "$DISK_SIZE" =~ ^[0-9]+G$ ]]; then
      echo -e "${DGN}${RD}Invalid Disk Size. Use a number (e.g., 32 or 32G).${CL}"
      exit-script
    fi
    echo -e "${DGN}Disk Size: ${BGN}$DISK_SIZE${CL}"
  else
    exit-script
  fi

  if DISK_CACHE1=$(whiptail --backtitle "Proxmox VE Helper Script" --title "DISK CACHE" \
    --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "None" OFF \
    "1" "Write Through (Default)" ON \
    3>&1 1>&2 2>&3); then
    if [ "$DISK_CACHE1" = "1" ]; then
      echo -e "${DGN}Disk Cache: ${BGN}Write Through${CL}"
      DISK_CACHE="cache=writethrough,"
    else
      echo -e "${DGN}Disk Cache: ${BGN}None${CL}"
      DISK_CACHE=""
    fi
  else
    exit-script
  fi

  if VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
    "Set Hostname" 8 58 "haos-${BRANCH}" --title "HOSTNAME" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$VM_NAME" ]; then
      HN="haos-${BRANCH}"
    else
      HN=$(echo "${VM_NAME,,}" | tr -d ' ')
    fi
    echo -e "${DGN}Hostname: ${BGN}$HN${CL}"
  else
    exit-script
  fi

  if CPU_TYPE1=$(whiptail --backtitle "Proxmox VE Helper Script" --title "CPU MODEL" \
    --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "KVM64" OFF \
    "1" "Host (Recommended for performance; no live migration)" ON \
    3>&1 1>&2 2>&3); then
    if [ "$CPU_TYPE1" = "1" ]; then
      echo -e "${DGN}CPU Model: ${BGN}Host${CL}"
      CPU_TYPE=" -cpu host"
    else
      echo -e "${DGN}CPU Model: ${BGN}KVM64${CL}"
      CPU_TYPE=""
    fi
  else
    exit-script
  fi

  if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
    "Allocate CPU Cores" 8 58 2 --title "CORE COUNT" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [[ -z "$CORE_COUNT" ]] && CORE_COUNT="2"
    echo -e "${DGN}CPU Cores: ${BGN}$CORE_COUNT${CL}"
  else
    exit-script
  fi

  if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
    "Allocate RAM in MiB" 8 58 4096 --title "RAM" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [[ -z "$RAM_SIZE" ]] && RAM_SIZE="4096"
    echo -e "${DGN}RAM Size: ${BGN}$RAM_SIZE MiB${CL}"
  else
    exit-script
  fi

  if BRG=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
    "Set a Bridge (must already exist, e.g., vmbr0)" 8 58 vmbr0 --title "BRIDGE" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [[ -z "$BRG" ]] && BRG="vmbr0"
    echo -e "${DGN}Bridge: ${BGN}$BRG${CL}"
  else
    exit-script
  fi

  if MAC1=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
    "Set a MAC Address" 8 58 "$GEN_MAC" --title "MAC ADDRESS" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$MAC1" ]; then
      MAC="$GEN_MAC"
    else
      MAC="$MAC1"
    fi
    echo -e "${DGN}MAC Address: ${BGN}$MAC${CL}"
  else
    exit-script
  fi

  if VLAN1=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
    "Set a VLAN (blank for default)" 8 58 --title "VLAN" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$VLAN1" ]; then
      VLAN=""
      echo -e "${DGN}VLAN: ${BGN}Default${CL}"
    else
      VLAN=",tag=$VLAN1"
      echo -e "${DGN}VLAN: ${BGN}$VLAN1${CL}"
    fi
  else
    exit-script
  fi

  if MTU1=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
    "Set Interface MTU Size (blank for default)" 8 58 --title "MTU SIZE" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$MTU1" ]; then
      MTU=""
      echo -e "${DGN}Interface MTU: ${BGN}Default${CL}"
    else
      MTU=",mtu=$MTU1"
      echo -e "${DGN}Interface MTU: ${BGN}$MTU1${CL}"
    fi
  else
    exit-script
  fi

  # Optional USB passthrough
  if (whiptail --backtitle "Proxmox VE Helper Script" --title "USB PASSTHROUGH" \
    --yesno "Add a USB device (e.g., Zigbee/Z-Wave stick) to the VM now?\nYou can also add this later in the Proxmox GUI." 10 70); then
    USB_PASSTHROUGH=$(whiptail --backtitle "Proxmox VE Helper Script" --inputbox \
      "Enter USB device as bus:device (output of 'lsusb' -> Bus XXX Device YYY, enter XXX:YYY)" \
      10 70 "001:002" --title "USB DEVICE (bus:device)" \
      --cancel-button Skip 3>&1 1>&2 2>&3 || echo "")
    if [[ -n "$USB_PASSTHROUGH" ]]; then
      echo -e "${DGN}USB Passthrough requested for host device: ${BGN}$USB_PASSTHROUGH${CL}"
      USB_SLOT="0"
    else
      echo -e "${DGN}USB Passthrough: ${BGN}None${CL}"
      USB_PASSTHROUGH=""
    fi
  else
    echo -e "${DGN}USB Passthrough: ${BGN}None${CL}"
    USB_PASSTHROUGH=""
  fi

  if (whiptail --backtitle "Proxmox VE Helper Script" --title "START VIRTUAL MACHINE" \
    --yesno "Start VM when completed?" 10 58); then
    echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
    START_VM="yes"
  else
    echo -e "${DGN}Start VM when completed: ${BGN}no${CL}"
    START_VM="no"
  fi

  if (whiptail --backtitle "Proxmox VE Helper Script" --title "ADVANCED SETTINGS COMPLETE" \
    --yesno "Ready to create HAOS ${BRANCH} VM?" --no-button Do-Over 10 58); then
    echo -e "${RD}Creating a HAOS VM using the above advanced settings${CL}"
  else
    header_info
    echo -e "${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Script" --title "SETTINGS" \
    --yesno "Use Default Settings?" --no-button Advanced 10 58); then
    header_info
    echo -e "${BL}Using Default Settings${CL}"
    default_settings
  else
    header_info
    echo -e "${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

# ---------- Run initial checks ----------
check_root
arch_check
pve_check
ssh_check
ensure_pv
ensure_xz

if whiptail --backtitle "Proxmox VE Helper Script" --title "HOME ASSISTANT OS VM" \
  --yesno "This will create a new Home Assistant OS VM. Proceed?" 10 70; then
  :
else
  header_info && echo -e "⚠ User exited script \n" && exit 1
fi

start_script

# ---------- Storage selection ----------
msg_info "Validating storage (images-capable pools)"
STORAGE_MENU=()
MSG_MAX_LENGTH=0
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  TYPE=$(echo "$line" | awk '{printf "%-10s", $2}')
  FREE=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + OFFSET)) -gt ${MSG_MAX_LENGTH:-0} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + OFFSET))
  fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')

VALID=$(pvesm status -content images | awk 'NR>1')
if [ -z "$VALID" ]; then
  msg_error "Unable to detect a valid storage location (content=images)."
  exit 1
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" > /dev/null 2>&1; then
      kill "$SPINNER_PID" > /dev/null 2>&1 || true
    fi
    printf "\e[?25h"
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Script" --title "Storage Pools" --radiolist \
      "Which storage pool would you like to use for ${HN}?\nTo make a selection, use the Spacebar.\n" \
      16 $((MSG_MAX_LENGTH + 23)) 6 \
      "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit 1
  done
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."

# ---------- Image download / import ----------
msg_info "Building HAOS download URL"
if [[ -n "${DEV_VER:-}" && "$BRANCH_VER" == "$DEV_VER" ]]; then
  DOWNLOAD_URL="https://os-artifacts.home-assistant.io/${BRANCH_VER}/haos_ova-${BRANCH_VER}.qcow2.xz"
else
  DOWNLOAD_URL="https://github.com/home-assistant/operating-system/releases/download/${BRANCH_VER}/haos_ova-${BRANCH_VER}.qcow2.xz"
fi
msg_ok "Download URL: $DOWNLOAD_URL"

CACHE_DIR="/var/lib/vz/template/cache"
CACHE_FILE="$CACHE_DIR/$(basename "$DOWNLOAD_URL")"

FILE_IMG="/var/lib/vz/template/tmp/${CACHE_FILE##*/%.xz}" # .qcow2

mkdir -p "$CACHE_DIR" "$(dirname "$FILE_IMG")"

msg_info "Retrieving Home Assistant ${BRANCH} disk image"
download_and_validate_xz "$DOWNLOAD_URL" "$CACHE_FILE"
msg_ok "${CL}${BL}${DOWNLOAD_URL}${CL}"

extract_xz_with_pv "$CACHE_FILE" "$FILE_IMG"

STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')

# Disk naming and reference format depends on storage type
case "$STORAGE_TYPE" in
  nfs | dir)
    # Directory-based: use subdir + .raw extension
    DISK_EXT=".raw"
    DISK_REF="$VMID/"
    DISK_IMPORT="-format raw"
    THIN=""
    ;;
  btrfs)
    # Btrfs: no subdir, no extension
    DISK_EXT=""
    DISK_REF=""
    DISK_IMPORT="-format raw"
    FORMAT=",efitype=4m"
    THIN=""
    ;;
  zfspool)
    # ZFS: no subdir, no extension, enable thin provisioning
    DISK_EXT=""
    DISK_REF=""
    DISK_IMPORT="-format raw"
    FORMAT=",efitype=4m"
    THIN="discard=on,ssd=1,"
    ;;
  lvmthin)
    # LVM-thin: no subdir, no extension, enable thin provisioning
    DISK_EXT=""
    DISK_REF=""
    DISK_IMPORT="-format raw"
    THIN="discard=on,ssd=1,"
    ;;
  *)
    # Fallback for other types (treat as block-based)
    DISK_EXT=""
    DISK_REF=""
    DISK_IMPORT="-format raw"
    THIN=""
    ;;
esac

DISK0="vm-${VMID}-disk-0${DISK_EXT}"
DISK1="vm-${VMID}-disk-1${DISK_EXT}"
DISK0_REF="${STORAGE}:${DISK_REF}${DISK0}"
DISK1_REF="${STORAGE}:${DISK_REF}${DISK1}"

msg_info "Creating Home Assistant OS VM"
qm create "$VMID" -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} \
  -cores "$CORE_COUNT" -memory "$RAM_SIZE" \
  -name "$HN" -tags home-assistant,helper-script \
  -net0 "virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU" -onboot 1 -ostype l26 -scsihw virtio-scsi-pci >/dev/null

pvesm alloc "$STORAGE" "$VMID" "$DISK0" 4M >/dev/null
qm importdisk "$VMID" "$FILE_IMG" "$STORAGE" ${DISK_IMPORT:-} >/dev/null

msg_ok "Imported HAOS disk image into $STORAGE"

msg_info "Attaching EFI and root disk"
qm set "$VMID" \
  -efidisk0 "${DISK0_REF}${FORMAT}" \
  -scsi0 "${DISK1_REF},${DISK_CACHE}${THIN}size=${DISK_SIZE}" \
  -boot order=scsi0 \
  -description "<div align='center'>
  <a href='https://www.home-assistant.io/' target='_blank' rel='noopener noreferrer'>
    <img src='https://avatars.githubusercontent.com/u/13844975?s=200&v=4' alt='Home Assistant' style='width:100px;height:100px;'/>
  </a>

  <h2 style='font-size: 20px; margin: 12px 0;'>Home Assistant OS</h2>

  <p style='margin: 12px 0;'>
    <a href='http://homeassistant.local:8123/config/dashboard' target='_blank' rel='noopener noreferrer'>
      <img src='https://img.shields.io/badge/&#x2615;-LAUNCH-blue' alt='Launch HA' />
    </a>
  </p>
</div>" >/dev/null

# Optional USB passthrough attach
if [[ -n "$USB_PASSTHROUGH" ]]; then
  msg_info "Attaching USB device $USB_PASSTHROUGH as usb${USB_SLOT}"
  qm set "$VMID" -usb${USB_SLOT} "host=$USB_PASSTHROUGH" >/dev/null
  msg_ok "Attached USB device $USB_PASSTHROUGH"
fi

msg_ok "Created Home Assistant OS VM ${CL}${BL}(${HN})"

# Optional: keep or delete cached image
if whiptail --backtitle "Proxmox VE Helper Script" --title "Image Cache" \
  --yesno "Keep downloaded Home Assistant OS image for future VMs?\n\nFile: $CACHE_FILE" 10 70; then
  msg_ok "Keeping cached image"
else
  rm -f "$CACHE_FILE"
  msg_ok "Deleted cached image"
fi

if [ "${START_VM:-yes}" = "yes" ]; then
  msg_info "Starting Home Assistant OS VM"
  qm start "$VMID" >/dev/null
  msg_ok "Started Home Assistant OS VM"
fi

msg_ok "Completed Successfully! Continue with Home Assistant onboarding in your browser per the official getting-started guide.[page:1]\n"
