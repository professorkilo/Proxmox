#!/usr/bin/env bash

# Copyright (c) 2026 professorkilo
# Author: professorkilo
# License: MIT
# https://github.com/professorkilo/Proxmox/raw/main/LICENSE

# This sets verbose mode if the global variable is set to "yes"
# if [[ "${VERBOSE:-}" == "yes" ]]; then set -x; fi

# This function sets color variables for formatting output in the terminal
YW="$(echo "\033[33m")"
BL="$(echo "\033[36m")"
RD="$(echo "\033[01;31m")"
GN="$(echo "\033[1;92m")"
CL="$(echo "\033[m")"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
BFR="\\r\\033[K"
HOLD=" "

# This sets error handling options and defines the error_handler function to handle errors
set -Eeuo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

# This function handles errors
error_handler() {
  if [[ -n "${SPINNER_PID:-}" ]] && ps -p "$SPINNER_PID" >/dev/null 2>&1; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
  fi

  printf "\e[?25h"

  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}${line_number}${CL}: exit code ${RD}${exit_code}${CL}: while executing command ${YW}${command}${CL}"

  echo -e "\n${error_message}\n"
}

# This function displays a spinner.
spinner() {
  local chars="/-\\|"
  local spin_i=0

  printf "\e[?25l"

  while true; do
    printf "\r \e[36m%s\e[0m" "${chars:spin_i++%${#chars}:1}"
    sleep 0.1
  done
}

# This function displays an informational message with a yellow color.
msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}   "
  spinner &
  SPINNER_PID=$!
}

# This function displays a success message with a green color.
msg_ok() {
  if [[ -n "${SPINNER_PID:-}" ]] && ps -p "$SPINNER_PID" >/dev/null 2>&1; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
  fi

  printf "\e[?25h"

  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

# This function displays an error message with a red color.
msg_error() {
  if [[ -n "${SPINNER_PID:-}" ]] && ps -p "$SPINNER_PID" >/dev/null 2>&1; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
  fi

  printf "\e[?25h"

  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

# This checks for the presence of valid Container Storage and Template Storage locations
msg_info "Validating Storage"

VALIDCT="$(pvesm status -content rootdir | awk 'NR>1')"
if [[ -z "$VALIDCT" ]]; then
  msg_error "Unable to detect a valid Container Storage location."
  exit 1
fi

VALIDTMP="$(pvesm status -content vztmpl | awk 'NR>1')"
if [[ -z "$VALIDTMP" ]]; then
  msg_error "Unable to detect a valid Template Storage location."
  exit 1
fi

msg_ok "Validated Storage"

# This function is used to select the storage class and determine the corresponding storage content type and label.
select_storage() {
  local CLASS="$1"
  local CONTENT
  local CONTENT_LABEL

  case "$CLASS" in
    container)
      CONTENT="rootdir"
      CONTENT_LABEL="Container"
      ;;
    template)
      CONTENT="vztmpl"
      CONTENT_LABEL="Container template"
      ;;
    *)
      msg_error "Invalid storage class: ${CLASS}"
      return 1
      ;;
  esac

  # This queries all storage locations.
  local -a MENU=()
  local line
  local TAG
  local TYPE
  local FREE
  local ITEM
  local OFFSET=2
  local MSG_MAX_LENGTH=0

  while read -r line; do
    TAG="$(awk '{print $1}' <<<"$line")"
    TYPE="$(awk '{printf "%-10s", $2}' <<<"$line")"
    FREE="$(numfmt --field 4-6 --from-unit=K --to=iec --format %.2f <<<"$line" | awk '{printf "%9sB", $6}')"
    ITEM="  Type: ${TYPE} Free: ${FREE} "

    if (( ${#ITEM} + OFFSET > MSG_MAX_LENGTH )); then
      MSG_MAX_LENGTH=$(( ${#ITEM} + OFFSET ))
    fi

    MENU+=("$TAG" "$ITEM" "OFF")
  done < <(pvesm status -content "$CONTENT" | awk 'NR>1')

  if (( ${#MENU[@]} == 0 )); then
    msg_error "No usable ${CONTENT_LABEL,,} storage was found."
    return 1
  fi

  # Select storage location.
  if (( ${#MENU[@]} / 3 == 1 )); then
    printf '%s' "${MENU[0]}"
    return 0
  fi

  local STORAGE=""
  while [[ -z "$STORAGE" ]]; do
    STORAGE="$(
      whiptail \
        --backtitle "Proxmox VE Helper Scripts" \
        --title "Storage Pools" \
        --radiolist \
        "Which storage pool would you like to use for the ${CONTENT_LABEL,,}?\nTo make a selection, use the Spacebar.\n" \
        16 "$((MSG_MAX_LENGTH + 23))" 6 \
        "${MENU[@]}" \
        3>&1 1>&2 2>&3
    )" || return 1
  done

  printf '%s' "$STORAGE"
}

# Test if required variables are set.
if [[ -z "${CTID:-}" ]]; then
  msg_error "You need to set the CTID variable."
  exit 1
fi

if [[ -z "${PCT_OSTYPE:-}" ]]; then
  msg_error "You need to set the PCT_OSTYPE variable."
  exit 1
fi

# Test if ID is valid.
if ! [[ "$CTID" =~ ^[0-9]+$ ]] || (( CTID < 100 )); then
  msg_error "Container ID must be a numeric value of 100 or greater."
  exit 1
fi

# Test if ID is in use.
if pct status "$CTID" &>/dev/null; then
  msg_error "ID '${CTID}' is already in use."
  exit 1
fi

# Get template storage.
TEMPLATE_STORAGE="$(select_storage template)" || {
  msg_error "Template storage selection was aborted."
  exit 1
}
msg_ok "Using ${BL}${TEMPLATE_STORAGE}${CL} ${GN}for Template Storage."

# Get container storage.
CONTAINER_STORAGE="$(select_storage container)" || {
  msg_error "Container storage selection was aborted."
  exit 1
}
msg_ok "Using ${BL}${CONTAINER_STORAGE}${CL} ${GN}for Container Storage."

# Update LXC template list.
msg_info "Updating LXC Template List"
if ! pveam update >/dev/null; then
  msg_error "Unable to update the LXC template list."
  exit 1
fi
msg_ok "Updated LXC Template List"

# Get the newest available template matching requested distribution and version.
TEMPLATE_SEARCH="${PCT_OSTYPE}-${PCT_OSVERSION:-}"

mapfile -t TEMPLATES < <(
  pveam available --section system \
    | sed -n "s/.*\(${TEMPLATE_SEARCH}.*\)/\1/p" \
    | sort -t - -k 2 -V
)

if (( ${#TEMPLATES[@]} == 0 )); then
  msg_error "Unable to find a template when searching for '${TEMPLATE_SEARCH}'."
  exit 1
fi

TEMPLATE="${TEMPLATES[-1]}"

# Download the LXC template only if the exact template is not already present.
if ! pveam list "$TEMPLATE_STORAGE" \
  | awk '{print $1}' \
  | grep -Fqx "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"; then

  msg_info "Downloading LXC Template"

  if ! pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null; then
    msg_error "A problem occurred while downloading the LXC template."
    echo "Storage: ${TEMPLATE_STORAGE}"
    echo "Template: ${TEMPLATE}"
    exit 1
  fi

  msg_ok "Downloaded LXC Template"
fi

# Combine all options.
DEFAULT_PCT_OPTIONS=(
  -arch "$(dpkg --print-architecture)"
)

PCT_OPTIONS=("${PCT_OPTIONS[@]:-${DEFAULT_PCT_OPTIONS[@]}}")

if [[ " ${PCT_OPTIONS[*]} " != *" -rootfs "* ]]; then
  PCT_OPTIONS+=(
    -rootfs "${CONTAINER_STORAGE}:${PCT_DISK_SIZE:-8}"
  )
fi

# Create container.
msg_info "Creating LXC Container"

if ! pct create \
  "$CTID" \
  "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  "${PCT_OPTIONS[@]}" \
  >/dev/null; then

  msg_error "A problem occurred while trying to create the container."
  exit 1
fi

msg_ok "LXC Container ${BL}${CTID}${CL} ${GN}was successfully created."
