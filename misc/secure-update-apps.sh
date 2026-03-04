#!/usr/bin/env bash

# ------------------------------------------------------------------------------
# Secure Proxmox LXC App Updater (Telemetry-Free) - Auto Start/Stop
# Description: Starts offline LXCs, checks for updates, executes them,
#              and returns the LXCs to their original power states.
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

UNATTENDED=0
if [[ "${1:-}" == "-y" || "${1:-}" == "--unattended" ]]; then
  UNATTENDED=1
fi

echo -e "${BL}Scanning Proxmox LXCs for updatable applications...${CL}"

CTID_LIST=$(pct list | tail -n +2 | awk '{print $1}' | grep -E '^[0-9]+$')
declare -A APP_NAMES
declare -A ORIGINAL_STATE
declare -a UPDATABLE_CTS

# Phase 1: Power State Management and Detection
for CTID in $CTID_LIST; do
  # Skip LXC templates
  if pct config "$CTID" | grep -q "template: 1"; then
    continue
  fi

  STATUS=$(pct status "$CTID" | awk '{print $2}')
  WAS_STOPPED=0

  # Power on dormant containers to check their filesystem
  if [[ "$STATUS" == "stopped" ]]; then
    WAS_STOPPED=1
    echo -e "${YW}[Info] Starting offline CT $CTID to check for updates...${CL}"
    pct start "$CTID"
    sleep 2 # Short delay to ensure the OS/Bash environment is initialized
  fi

  # Security Check 2: Check for update binary locally
  if pct exec "$CTID" -- sh -c "command -v update >/dev/null 2>&1"; then
    HOSTNAME=$(pct exec "$CTID" hostname 2>/dev/null || pct config "$CTID" | awk '/^hostname/ {print $2}')
    APP_NAMES[$CTID]="${HOSTNAME:-Unknown}"
    UPDATABLE_CTS+=("$CTID")
    ORIGINAL_STATE[$CTID]=$WAS_STOPPED
  else
    # If no update script exists, and we started it, shut it back down immediately
    if [[ $WAS_STOPPED -eq 1 ]]; then
      echo -e "${YW}[Info] No app update script in CT $CTID. Returning to stopped state...${CL}"
      pct stop "$CTID"
    fi
  fi
done

if [[ ${#UPDATABLE_CTS[@]} -eq 0 ]]; then
  echo -e "${YW}[Info] No containers with application 'update' scripts found.${CL}"
  exit 0
fi

SELECTED_CTS=""

# Phase 2: User Selection
if [[ $UNATTENDED -eq 1 ]]; then
  SELECTED_CTS="${UPDATABLE_CTS[*]}"
else
  MENU_OPTIONS=()
  for CTID in "${UPDATABLE_CTS[@]}"; do
    MENU_OPTIONS+=("$CTID" "${APP_NAMES[$CTID]}" "ON")
  done

  SELECTED_CTS=$(whiptail --title "Secure LXC Application Updater" --checklist \
    "Select applications to update:\n(Press Space to toggle, Enter to confirm)" \
    20 60 10 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3 | tr -d '"')

  if [[ -z "$SELECTED_CTS" ]]; then
    echo -e "${YW}[Info] Update cancelled or no containers selected. Cleaning up...${CL}"
    # Cleanup: politely shut down the containers we started if user cancels
    for CTID in "${UPDATABLE_CTS[@]}"; do
      if [[ ${ORIGINAL_STATE[$CTID]} -eq 1 ]]; then
        pct stop "$CTID"
      fi
    done
    exit 0
  fi
fi

# Phase 3: Process Selected Updates
for CTID in $SELECTED_CTS; do
  echo -e "\n${GN}================================================================${CL}"
  echo -e "${GN} Updating Application in CT $CTID (${APP_NAMES[$CTID]})...${CL}"
  echo -e "${GN}================================================================${CL}"
  
  # Isolated execution environment with auto-approval
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

# Phase 4: Final Cleanup / Restore Power States
echo -e "${BL}Restoring container power states...${CL}"
for CTID in "${UPDATABLE_CTS[@]}"; do
  if [[ ${ORIGINAL_STATE[$CTID]} -eq 1 ]]; then
    echo -e "${YW}[Info] Shutting down CT $CTID to return to original state...${CL}"
    pct stop "$CTID"
  fi
done

echo -e "${GN}All operations completed securely!${CL}"
