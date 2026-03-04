#!/usr/bin/env bash

# ------------------------------------------------------------------------------
# Secure Proxmox LXC App Updater (Telemetry-Free)
# Description: Replaces the community-scripts 'update-apps' without external 
#              API calls, telemetry tracking, or remote script sourcing.
# ------------------------------------------------------------------------------

set -e # Exit on critical host errors

# UI Colors
GN="\033[1;92m"
RD="\033[01;31m"
BL="\033[36m"
YW="\033[33m"
CL="\033[m"

# Security Check 1: Prevent execution without proper privileges
if [[ "$(id -u)" -ne 0 ]]; then
  echo -e "${RD}[Error] This script must be run as root.${CL}"
  exit 1
fi

# Allow for cron automation if passed with '-y' or '--unattended'
UNATTENDED=0
if [[ "${1:-}" == "-y" || "${1:-}" == "--unattended" ]]; then
  UNATTENDED=1
fi

echo -e "${BL}Scanning Proxmox LXCs for updatable applications...${CL}"

# Security Check 2: Safe parsing of the pct list (only accepts numeric IDs)
CTID_LIST=$(pct list | tail -n +2 | awk '{print $1}' | grep -E '^[0-9]+$')
declare -A APP_NAMES
declare -a UPDATABLE_CTS

for CTID in $CTID_LIST; do
  STATUS=$(pct status "$CTID" | awk '{print $2}')
  if [[ "$STATUS" == "running" ]]; then
    # Security Check 3: Check for update binary locally without downloading remote detection scripts
    if pct exec "$CTID" -- sh -c "command -v update >/dev/null 2>&1"; then
      HOSTNAME=$(pct exec "$CTID" hostname 2>/dev/null || pct config "$CTID" | awk '/^hostname/ {print $2}')
      APP_NAMES[$CTID]="${HOSTNAME:-Unknown}"
      UPDATABLE_CTS+=("$CTID")
    fi
  fi
done

if [[ ${#UPDATABLE_CTS[@]} -eq 0 ]]; then
  echo -e "${YW}[Info] No running containers with application 'update' scripts found.${CL}"
  exit 0
fi

SELECTED_CTS=""

if [[ $UNATTENDED -eq 1 ]]; then
  # If unattended, automatically select all updatable containers
  SELECTED_CTS="${UPDATABLE_CTS[*]}"
else
  # Build the interactive whiptail menu
  MENU_OPTIONS=()
  for CTID in "${UPDATABLE_CTS[@]}"; do
    MENU_OPTIONS+=("$CTID" "${APP_NAMES[$CTID]}" "ON")
  done

  # Security Check 4: Sanitize whiptail user output
  SELECTED_CTS=$(whiptail --title "Secure LXC Application Updater" --checklist \
    "Select applications to update:\n(Press Space to toggle, Enter to confirm)" \
    20 60 10 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3 | tr -d '"')

  if [[ -z "$SELECTED_CTS" ]]; then
    echo -e "${YW}[Info] Update cancelled or no containers selected.${CL}"
    exit 0
  fi
fi

# Process Selected Updates
for CTID in $SELECTED_CTS; do
  echo -e "\n${GN}================================================================${CL}"
  echo -e "${GN} Updating Application in CT $CTID (${APP_NAMES[$CTID]})...${CL}"
  echo -e "${GN}================================================================${CL}"
  
  # Security Check 5: Isolated execution environment with auto-approval
  # We temporarily disable 'set -e' so a failed update doesn't crash the entire host loop
  set +e
  pct exec "$CTID" -- bash -c "yes | update"
  EXIT_CODE=$?
  set -e
  
  if [[ $EXIT_CODE -ne 0 ]]; then
    echo -e "${RD}[Error] Update encountered an issue in CT $CTID (Exit Code: $EXIT_CODE)${CL}"
  else
    echo -e "${BL}[Success] Finished updating CT $CTID${CL}\n"
  fi
done

echo -e "${GN}All selected updates completed securely!${CL}"
