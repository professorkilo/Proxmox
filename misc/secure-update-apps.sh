#!/usr/bin/env bash

# ------------------------------------------------------------------------------
# Sequential Proxmox LXC App Updater (Telemetry-Free)
# Description: Iterates through Proxmox LXCs ONE AT A TIME. If offline, it
#              starts the LXC, checks/runs the application update, and
#              shuts it back down before moving to the next container.
# ------------------------------------------------------------------------------

set -e # Exit on critical host errors

GN="\033[1;92m"
RD="\033[01;31m"
BL="\033[36m"
YW="\033[33m"
CL="\033[m"

if [[ "$(id -u)" -ne 0 ]]; then
  echo -e "${RD}[Error] This script must be run as root.${CL}"
  exit 1
fi

echo -e "${BL}Starting Sequential LXC Application Updater...${CL}"

# Get all LXC container IDs (excluding templates safely)
CTID_LIST=$(pct list | tail -n +2 | awk '{print $1}' | grep -E '^[0-9]+$')

for CTID in $CTID_LIST; do
  # Skip LXC templates
  if pct config "$CTID" | grep -q "template: 1"; then
    continue
  fi

  # Gather basic info for logging
  HOSTNAME=$(pct config "$CTID" | awk '/^hostname/ {print $2}')
  HOSTNAME=${HOSTNAME:-Unknown}
  STATUS=$(pct status "$CTID" | awk '{print $2}')
  WAS_STOPPED=0

  echo -e "\n${BL}------------------------------------------------------------------------${CL}"
  echo -e "${BL} Processing CT $CTID : $HOSTNAME...${CL}"
  echo -e "${BL}------------------------------------------------------------------------${CL}"

  # Step 1: Start the container if it is offline
  if [[ "$STATUS" == "stopped" ]]; then
    WAS_STOPPED=1
    echo -e "${YW}[Info] CT $CTID is offline. Starting it up...${CL}"
    pct start "$CTID"
    # Wait 3 seconds to ensure the network and bash environment are fully initialized
    sleep 3 
  fi

  # Step 2: Check for the app update script and run it
  if pct exec "$CTID" -- sh -c "command -v update >/dev/null 2>&1"; then
    echo -e "${GN}[Info] 'update' command found. Running application update...${CL}"
    
    # Temporarily disable exit-on-error so a single app failure doesn't break the entire loop
    set +e
    pct exec "$CTID" -- sh -c "yes | update"
    EXIT_CODE=$?
    set -e
    
    if [[ $EXIT_CODE -ne 0 ]]; then
      echo -e "${RD}[Error] Update failed for CT $CTID (Exit Code: $EXIT_CODE)${CL}"
    else
      echo -e "${GN}[Success] CT $CTID application update complete.${CL}"
    fi
  else
    echo -e "${YW}[Skip] No app-level 'update' command found. Moving on.${CL}"
  fi

  # Step 3: Shut the container back down ONLY if we started it
  if [[ $WAS_STOPPED -eq 1 ]]; then
    echo -e "${YW}[Info] Returning CT $CTID to offline state...${CL}"
    pct stop "$CTID"
  fi

done

echo -e "\n${GN}================================================================${CL}"
echo -e "${GN} All Proxmox LXCs have been processed sequentially!${CL}"
echo -e "${GN}================================================================${CL}"
