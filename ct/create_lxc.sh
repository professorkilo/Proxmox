#!/usr/bin/env bash

# Copyright (c) 2021-2026 professorkilo
# Author: professorkilo
# License: MIT
# https://github.com/professorkilo/Proxmox/raw/main/LICENSE

set -Eeuo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND" "$?"' ERR

YW="\033[33m"
BL="\033[36m"
RD="\033[01;31m"
GN="\033[1;92m"
CL="\033[m"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
BFR="\r\033[K"
HOLD=" "
SPINNER_PID=""

error_handler() {
  local line_number="$1"
  local command="$2"
  local exit_code="$3"

  if [[ -n "${SPINNER_PID:-}" ]] && kill -0 "$SPINNER_PID" >/dev/null 2>&1; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
  fi

  printf "\e[?25h"
  echo -e "\n${RD}[ERROR]${CL} line ${RD}${line_number}${CL}, exit code ${RD}${exit_code}${CL}: ${YW}${command}${CL}\n"
}

spinner() {
  local chars="/-\\|"
  local spin_i=0

  printf "\e[?25l"

  while true; do
    printf "\r \e[36m%s\e[0m" "${chars:spin_i++ % ${#chars}:1}"
    sleep 0.1
  done
}

msg_info() {
  local msg="$1"

  echo -ne " ${HOLD} ${YW}${msg}   "
  spinner &
  SPINNER_PID=$!
}

stop_spinner() {
  if [[ -n "${SPINNER_PID:-}" ]] && kill -0 "$SPINNER_PID" >/dev/null 2>&1; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
  fi

  SPINNER_PID=""
  printf "\e[?25h"
}

msg_ok() {
  local msg="$1"

  stop_spinner
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"

  stop_spinner
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

die() {
  msg_error "$1"
  exit "${2:-1}"
}

select_storage() {
  local class="$1"
  local content
  local content_label
  local -a menu=()
  local line
  local tag
  local type
  local free
  local item
  local max_length=0
  local selected_storage=""

  case "$class" in
    container)
      content="rootdir"
      content_label="Container"
      ;;
    template)
      content="vztmpl"
      content_label="Container template"
      ;;
    *)
      die "Invalid storage class: ${class}"
      ;;
  esac

  while read -r line; do
    tag="$(awk '{print $1}' <<< "$line")"
    type="$(awk '{printf "%-10s", $2}' <<< "$line")"
    free="$(numfmt --field 4-6 --from-unit=K --to=iec --format "%.2f" <<< "$line" | awk '{printf "%9sB", $6}')"
    item="  Type: ${type} Free: ${free} "

    (( ${#item} > max_length )) && max_length="${#item}"
    menu+=("$tag" "$item" "OFF")
  done < <(pvesm status -content "$content" | awk 'NR > 1')

  (( ${#menu[@]} > 0 )) || die "No usable ${content_label,,} storage was found."

  if (( ${#menu[@]} == 3 )); then
    printf '%s' "${menu[0]}"
    return 0
  fi

  selected_storage="$(
    whiptail \
      --backtitle "Proxmox VE Helper Scripts" \
      --title "Storage Pools" \
      --radiolist \
      "Which storage pool would you like to use for the ${content_label,,}?\nTo make a selection, use the Spacebar.\n" \
      16 "$((max_length + 25))" 6 \
      "${menu[@]}" \
      3>&1 1>&2 2>&3
  )" || return 1

  [[ -n "$selected_storage" ]] || return 1
  printf '%s' "$selected_storage"
}

require_var() {
  local var_name="$1"
  local value="${!var_name:-}"

  [[ -n "$value" ]] || die "Required variable '${var_name}' is not set."
}

validate_numeric() {
  local value="$1"
  local label="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || die "${label} must be numeric."
}

template_exists() {
  local storage="$1"
  local template="$2"

  pveam list "$storage" \
    | awk '{print $1}' \
    | grep -Fqx "${storage}:vztmpl/${template}"
}

load_pct_options() {
  local option
  PCT_OPTIONS=()

  if [[ -n "${PCT_OPTIONS_SERIALIZED:-}" ]]; then
    while IFS= read -r option; do
      [[ -n "$option" ]] && PCT_OPTIONS+=("$option")
    done <<< "$PCT_OPTIONS_SERIALIZED"
  fi

  PCT_OPTIONS=(
    -arch "$(dpkg --print-architecture)"
    "${PCT_OPTIONS[@]}"
  )
}

require_var "CTID"
require_var "PCT_OSTYPE"

validate_numeric "$CTID" "Container ID"
(( CTID >= 100 )) || die "Container ID must be 100 or greater."

if pct status "$CTID" >/dev/null 2>&1; then
  die "Container ID '${CTID}' is already in use."
fi

msg_info "Validating Storage"

if ! pvesm status -content rootdir | awk 'NR > 1 { found=1 } END { exit !found }'; then
  die "Unable to detect a valid Container Storage location."
fi

if ! pvesm status -content vztmpl | awk 'NR > 1 { found=1 } END { exit !found }'; then
  die "Unable to detect a valid Template Storage location."
fi

msg_ok "Validated Storage"

TEMPLATE_STORAGE="$(select_storage template)" || die "Template storage selection was aborted."
msg_ok "Using ${BL}${TEMPLATE_STORAGE}${CL} ${GN}for Template Storage."

CONTAINER_STORAGE="$(select_storage container)" || die "Container storage selection was aborted."
msg_ok "Using ${BL}${CONTAINER_STORAGE}${CL} ${GN}for Container Storage."

msg_info "Updating LXC Template List"

if ! pveam update >/dev/null; then
  die "Unable to update the LXC template list."
fi

msg_ok "Updated LXC Template List"

TEMPLATE_SEARCH="${PCT_OSTYPE}-${PCT_OSVERSION:-}"

mapfile -t TEMPLATES < <(
  pveam available --section system \
    | awk -v search="$TEMPLATE_SEARCH" '$2 ~ ("^" search) { print $2 }' \
    | sort -V
)

(( ${#TEMPLATES[@]} > 0 )) || die "Unable to find an LXC template matching '${TEMPLATE_SEARCH}'."

TEMPLATE="${TEMPLATES[-1]}"

if ! template_exists "$TEMPLATE_STORAGE" "$TEMPLATE"; then
  msg_info "Downloading LXC Template"

  if ! pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null; then
    stop_spinner
    echo "Storage: ${TEMPLATE_STORAGE}"
    echo "Template: ${TEMPLATE}"
    die "A problem occurred while downloading the LXC template."
  fi

  msg_ok "Downloaded LXC Template"
fi

load_pct_options

if [[ " ${PCT_OPTIONS[*]} " != *" -rootfs "* ]]; then
  PCT_OPTIONS+=(
    -rootfs "${CONTAINER_STORAGE}:${PCT_DISK_SIZE:-8}"
  )
fi

msg_info "Creating LXC Container"

if ! pct create \
  "$CTID" \
  "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  "${PCT_OPTIONS[@]}" \
  >/dev/null; then

  die "A problem occurred while trying to create the container."
fi

msg_ok "LXC Container ${BL}${CTID}${CL} ${GN}was successfully created."
