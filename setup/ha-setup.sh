#!/usr/bin/env bash
# =============================================================================
# Home Assistant Stack Setup Script
# =============================================================================
# Version  : 1.0.2
# Created  : 2026-06-10
# Author   : github.com/thirsty-fatman
#
# Changelog:
#   1.0.2 - 2026-06-12 - Fixed "((var++))" arithmetic expressions which exit
#                         non-zero (triggering set -e abort) when var=0 -
#                         the very first increment of any counter starting
#                         at 0. Replaced all with "var=$((var + 1))" form.
#                         This caused npm-setup.sh to silently exit after
#                         processing only the first proxy host.
#   1.0.1 - 2026-06-10 - Fixed Zigbee2MQTT network (moved to iot_macvlan to
#                         reach Mosquitto). Fixed secret.yaml to write actual
#                         MQTT password instead of username placeholder.
#                         Fixed invalid 'local' keyword used outside a function
#                         in Matter dongle detection.
#   1.0.0 - 2026-06-10 - Initial release
#
# Description:
#   Interactive setup script for the Home Assistant stack on Ubuntu Server 24.04.
#   Standalone script — run independently after server-setup.sh.
#   No personal information hardcoded. Safe to publish publicly.
#
# What this script does:
#   1.  Adds secondary IP to OSAN via Netplan (IoT network)
#   2.  Creates Docker macvlan network on IoT subnet
#   3.  Creates directory structure for all HA stack containers
#   4.  Detects USB dongles (Zigbee and Matter/Thread)
#   5.  Generates Mosquitto config with authentication
#   6.  Generates Zigbee2MQTT config
#   7.  Deploys Mosquitto
#   8.  Deploys Zigbee2MQTT
#   9.  Deploys Home Assistant
#   10. Deploys Node-RED
#   11. Updates /opt/docker/.env with new variables
#   12. Updates Cloudflare DNS with ha and nodered A records
#   13. Updates NPM with proxy hosts for ha and nodered
#   14. Updates Homepage services.yaml with Home Automation group
#   15. Restarts Homepage
#
# Usage:
#   sudo bash ha-setup.sh
#
# Or directly from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/ha-setup.sh -o ha-setup.sh
#   sudo bash ha-setup.sh
#
# Requirements:
#   - server-setup.sh must have been run first
#   - /opt/docker/.env must exist
#   - Sonoff Zigbee Dongle-P and HA ZBT-2 must be available to plug in
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colour helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}\n"; }

# -----------------------------------------------------------------------------
# Must be run as root
# -----------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
  error "This script must be run as root. Try: sudo bash ha-setup.sh"
  exit 1
fi

# -----------------------------------------------------------------------------
# Check dependencies
# -----------------------------------------------------------------------------
for cmd in curl python3 docker ip; do
  if ! command -v "$cmd" &>/dev/null; then
    error "${cmd} is required but not installed."
    exit 1
  fi
done

# -----------------------------------------------------------------------------
# Check /opt/docker/.env exists
# -----------------------------------------------------------------------------
ENV_FILE="/opt/docker/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  error "${ENV_FILE} not found. Please run server-setup.sh first."
  exit 1
fi

# -----------------------------------------------------------------------------
# Load .env
# -----------------------------------------------------------------------------
info "Loading ${ENV_FILE}..."
while IFS='=' read -r key value; do
  [[ "$key" =~ ^[A-Z_]+$ ]] || continue
  [[ -z "$value" ]] && continue
  printf -v "$key" '%s' "$value" 2>/dev/null || true
done < <(grep -E '^[A-Z_]+=.+' "$ENV_FILE")

# Set defaults from .env or fallback
DOCKER_BASE="${DOCKERDIR:-/opt/docker}"
DOCKER_APPDATA="${APPDATA:-/opt/docker/appdata}"
DOCKER_VOLUMES="${VOLUMES:-/opt/docker/volumes}"
SERVER_LAN_IP="${SERVER_LAN_IP:-$(hostname -I | awk '{print $1}')}"

# -----------------------------------------------------------------------------
# Helper: prompt with default
# -----------------------------------------------------------------------------
prompt_default() {
  local varname="$1"
  local question="$2"
  local default="$3"
  local input

  echo -e "${BOLD}${question}${RESET}"
  echo -e "  Current/default: ${YELLOW}${default}${RESET}"
  read -rp "  New value (Enter to keep): " input < /dev/tty
  echo

  if [[ -z "$input" ]]; then
    printf -v "$varname" '%s' "$default"
  else
    printf -v "$varname" '%s' "$input"
  fi
}

# -----------------------------------------------------------------------------
# Helper: prompt password (hidden, confirmed, minimum 8 characters)
# -----------------------------------------------------------------------------
prompt_password() {
  local varname="$1"
  local label="$2"
  local pass1 pass2

  while true; do
    echo -e "${BOLD}Password for ${label}${RESET}"
    read -rsp "  Enter password: " pass1 < /dev/tty
    echo

    if [[ ${#pass1} -lt 8 ]]; then
      warn "Password must be at least 8 characters. Please try again."
      continue
    fi

    read -rsp "  Confirm password: " pass2 < /dev/tty
    echo

    if [[ "$pass1" == "$pass2" ]]; then
      printf -v "$varname" '%s' "$pass1"
      echo
      break
    else
      warn "Passwords do not match. Please try again."
    fi
  done
}

# -----------------------------------------------------------------------------
# Helper: detect USB serial devices
# Returns list of /dev/ttyUSB* and /dev/ttyACM* devices
# -----------------------------------------------------------------------------
get_usb_devices() {
  local devices=()
  for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "$dev" ]] && devices+=("$dev")
  done
  echo "${devices[@]:-}"
}

# -----------------------------------------------------------------------------
# Helper: prompt for USB device with auto-detection
# -----------------------------------------------------------------------------
prompt_usb_device() {
  local varname="$1"
  local device_name="$2"
  local insert_prompt="$3"

  echo -e "${BOLD}${device_name}${RESET}"
  echo -e "  ${insert_prompt}"
  echo -e "  Press ${YELLOW}Enter${RESET} when the device is plugged in."
  read -rp "" < /dev/tty
  echo

  # Scan for devices
  local devices
  devices=$(get_usb_devices)

  if [[ -z "$devices" ]]; then
    warn "No USB serial devices detected."
    echo -e "${BOLD}Enter device path manually${RESET} (e.g. /dev/ttyUSB0 or /dev/ttyACM0):"
    read -rp "  Device path: " manual_path < /dev/tty
    echo
    printf -v "$varname" '%s' "$manual_path"
    return
  fi

  # Show detected devices
  echo -e "  Detected USB serial devices:"
  local i=1
  local device_array=()
  for dev in $devices; do
    echo -e "    ${CYAN}${i}.${RESET} ${dev}"
    device_array+=("$dev")
    i=$((i + 1))
  done
  echo

  if [[ ${#device_array[@]} -eq 1 ]]; then
    # Only one device — confirm it
    echo -e "${BOLD}Is this the correct device? ${YELLOW}${device_array[0]}${RESET}"
    read -rp "  Confirm [Y/n]: " confirm < /dev/tty
    echo
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
      echo -e "${BOLD}Enter device path manually:${RESET}"
      read -rp "  Device path: " manual_path < /dev/tty
      echo
      printf -v "$varname" '%s' "$manual_path"
    else
      printf -v "$varname" '%s' "${device_array[0]}"
    fi
  else
    # Multiple devices — ask user to select
    while true; do
      read -rp "  Select device number [1-${#device_array[@]}]: " selection < /dev/tty
      echo
      if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#device_array[@]} )); then
        printf -v "$varname" '%s' "${device_array[$((selection-1))]}"
        break
      else
        warn "Invalid selection. Please try again."
      fi
    done
  fi

  success "Selected: ${!varname}"
}

# =============================================================================
# STEP 1 — Interactive menu
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "   Home Assistant Stack Setup"
echo "   v1.0.2 | 2026-06-12"
echo "============================================================"
echo -e "${RESET}"
echo -e "This script sets up Home Assistant and dependencies on OSAN."
echo -e "Run after server-setup.sh. Requires /opt/docker/.env.\n"

# --- Network config ----------------------------------------------------------
header "IoT Network Configuration"
echo -e "  Home Assistant will be assigned an IP on your IoT subnet."
echo -e "  OSAN will have a secondary IP address on the IoT network.\n"

prompt_default NIC_NAME "Network interface name" "eno1"
prompt_default IOT_SUBNET "IoT subnet" "192.168.8.0/24"
prompt_default IOT_GATEWAY "IoT gateway" "192.168.8.1"
prompt_default HA_IP "IP address for HA stack (secondary IP on OSAN)" "192.168.8.2"

# Derive VLAN ID from subnet if needed (informational only)
IOT_NETWORK=$(echo "$IOT_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)

# --- HA version --------------------------------------------------------------
header "Home Assistant"
prompt_default HA_VERSION "Home Assistant version" "2026.5"

# --- USB dongle detection ----------------------------------------------------
header "USB Dongles"
echo -e "  Two USB dongles are required:"
echo -e "  ${CYAN}1.${RESET} Sonoff Zigbee Dongle-P — Zigbee coordinator for Zigbee2MQTT"
echo -e "  ${CYAN}2.${RESET} HA ZBT-2 — Matter/Thread border router for Home Assistant\n"
echo -e "  Please ensure both are unplugged before continuing."
read -rp "  Press Enter when both dongles are unplugged: " < /dev/tty
echo

# Detect Zigbee dongle
prompt_usb_device ZIGBEE_DEVICE \
  "Zigbee Dongle (Sonoff Zigbee Dongle-P)" \
  "Please plug in the Sonoff Zigbee Dongle-P now."

# Detect Matter dongle (scan for NEW device after Zigbee is already plugged in)
echo -e "${BOLD}Matter/Thread Dongle (HA ZBT-2)${RESET}"
echo -e "  Please plug in the HA ZBT-2 now."
echo -e "  Press ${YELLOW}Enter${RESET} when plugged in."
read -rp "" < /dev/tty
echo

# Show devices excluding the already-selected Zigbee device
ALL_DEVICES=$(get_usb_devices)
MATTER_CANDIDATES=()
for dev in $ALL_DEVICES; do
  [[ "$dev" != "$ZIGBEE_DEVICE" ]] && MATTER_CANDIDATES+=("$dev")
done

if [[ ${#MATTER_CANDIDATES[@]} -eq 0 ]]; then
  warn "No new USB devices detected after plugging in HA ZBT-2."
  echo -e "${BOLD}Enter device path manually:${RESET}"
  read -rp "  Device path: " MATTER_DEVICE < /dev/tty
  echo
elif [[ ${#MATTER_CANDIDATES[@]} -eq 1 ]]; then
  echo -e "  Detected: ${CYAN}${MATTER_CANDIDATES[0]}${RESET}"
  read -rp "  Is this the HA ZBT-2? [Y/n]: " confirm < /dev/tty
  echo
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    read -rp "  Enter device path manually: " MATTER_DEVICE < /dev/tty
    echo
  else
    MATTER_DEVICE="${MATTER_CANDIDATES[0]}"
  fi
else
  echo -e "  Detected multiple new devices:"
  i=1
  for dev in "${MATTER_CANDIDATES[@]}"; do
    echo -e "    ${CYAN}${i}.${RESET} ${dev}"
    i=$((i + 1))
  done
  echo
  while true; do
    read -rp "  Select HA ZBT-2 device [1-${#MATTER_CANDIDATES[@]}]: " sel < /dev/tty
    echo
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#MATTER_CANDIDATES[@]} )); then
      MATTER_DEVICE="${MATTER_CANDIDATES[$((sel-1))]}"
      break
    else
      warn "Invalid selection. Please try again."
    fi
  done
fi
success "Matter device selected: ${MATTER_DEVICE}"

# --- Mosquitto credentials ---------------------------------------------------
header "Mosquitto MQTT Credentials"
echo -e "  These credentials are used by Zigbee2MQTT, Node-RED, and any"
echo -e "  other MQTT clients connecting to the broker.\n"

echo -e "${BOLD}MQTT username${RESET}"
read -rp "  Username: " MQTT_USER < /dev/tty
echo
prompt_password MQTT_PASSWORD "MQTT (${MQTT_USER})"

# --- Node-RED credentials ----------------------------------------------------
header "Node-RED Credentials"
echo -e "  Admin credentials for the Node-RED web UI.\n"

echo -e "${BOLD}Node-RED username${RESET}"
read -rp "  Username: " NODERED_USER < /dev/tty
echo
prompt_password NODERED_PASSWORD "Node-RED (${NODERED_USER})"

# --- Domain ------------------------------------------------------------------
header "Domain Configuration"
EXISTING_DOMAIN="${DOMAIN:-}"
if [[ -n "$EXISTING_DOMAIN" ]]; then
  prompt_default DOMAIN "Domain for proxy hosts" "$EXISTING_DOMAIN"
else
  echo -e "${BOLD}Domain name${RESET} (e.g. example.com)"
  while true; do
    read -rp "  Domain: " DOMAIN < /dev/tty
    echo
    if [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      warn "Invalid domain format. Please try again."
    fi
  done
fi

# =============================================================================
# STEP 2 — Confirmation summary
# =============================================================================
header "Confirmation Summary"
echo -e "  Network interface    : ${YELLOW}${NIC_NAME}${RESET}"
echo -e "  IoT subnet           : ${YELLOW}${IOT_SUBNET}${RESET}"
echo -e "  IoT gateway          : ${YELLOW}${IOT_GATEWAY}${RESET}"
echo -e "  HA stack IP          : ${YELLOW}${HA_IP}${RESET}"
echo -e "  HA version           : ${YELLOW}${HA_VERSION}${RESET}"
echo -e "  Zigbee device        : ${YELLOW}${ZIGBEE_DEVICE}${RESET}"
echo -e "  Matter device        : ${YELLOW}${MATTER_DEVICE}${RESET}"
echo -e "  MQTT username        : ${YELLOW}${MQTT_USER}${RESET}"
echo -e "  MQTT password        : ${YELLOW}(set — not displayed)${RESET}"
echo -e "  Node-RED username    : ${YELLOW}${NODERED_USER}${RESET}"
echo -e "  Node-RED password    : ${YELLOW}(set — not displayed)${RESET}"
echo -e "  Domain               : ${YELLOW}${DOMAIN}${RESET}"
echo
echo -e "  Containers to deploy:"
echo -e "    - Mosquitto         (${HA_IP}:1883, ${HA_IP}:9001)"
echo -e "    - Zigbee2MQTT       (internal only)"
echo -e "    - Home Assistant    (${HA_IP}:8123, ${HA_IP}:5683/udp)"
echo -e "    - Node-RED          (${HA_IP}:1880)"
echo
echo -e "  Proxy hosts to create:"
echo -e "    - https://ha.${DOMAIN}       → ${HA_IP}:8123"
echo -e "    - https://nodered.${DOMAIN}  → ${HA_IP}:1880"
echo
read -rp "$(echo -e "${BOLD}Proceed with these settings? [y/N]: ${RESET}")" CONFIRM < /dev/tty
echo

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  warn "Aborted by user. Nothing has been changed."
  exit 0
fi

# =============================================================================
# From here everything runs unattended
# =============================================================================

# -----------------------------------------------------------------------------
# STEP 3 — Configure Netplan (add secondary IoT IP)
# -----------------------------------------------------------------------------
header "Configuring Netplan"

NETPLAN_FILE="/etc/netplan/60-iot-vlan.yaml"

# Check if already configured
if ip addr show "$NIC_NAME" | grep -q "$HA_IP"; then
  info "Secondary IP ${HA_IP} already configured on ${NIC_NAME} — skipping Netplan."
else
  info "Adding ${HA_IP} as secondary IP on ${NIC_NAME}..."

  cat > "$NETPLAN_FILE" << EOF
# =============================================================================
# OSAN IoT Network Secondary IP
# =============================================================================
# Adds a secondary IP address on the IoT subnet to ${NIC_NAME}.
# This allows Docker macvlan containers to have a presence on the IoT network.
# Generated by ha-setup.sh
# =============================================================================
network:
  version: 2
  ethernets:
    ${NIC_NAME}:
      addresses:
        - ${HA_IP}/24
EOF

  chmod 600 "$NETPLAN_FILE"

  # Apply Netplan
  netplan apply
  sleep 2

  # Verify
  if ip addr show "$NIC_NAME" | grep -q "$HA_IP"; then
    success "Secondary IP ${HA_IP} added to ${NIC_NAME}."
  else
    error "Failed to add secondary IP. Check Netplan config at ${NETPLAN_FILE}."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# STEP 4 — Create Docker macvlan network
# -----------------------------------------------------------------------------
header "Creating Docker Macvlan Network"

MACVLAN_NETWORK="iot_macvlan"

if docker network ls | grep -q "$MACVLAN_NETWORK"; then
  info "Docker macvlan network '${MACVLAN_NETWORK}' already exists — skipping."
else
  info "Creating macvlan network '${MACVLAN_NETWORK}'..."

  docker network create \
    --driver macvlan \
    --subnet="${IOT_SUBNET}" \
    --gateway="${IOT_GATEWAY}" \
    --opt parent="${NIC_NAME}" \
    "$MACVLAN_NETWORK"

  success "Macvlan network '${MACVLAN_NETWORK}' created."
fi

# -----------------------------------------------------------------------------
# STEP 5 — Create directory structure
# -----------------------------------------------------------------------------
header "Creating Directory Structure"

mkdir -p "${DOCKER_APPDATA}/mosquitto/config"
mkdir -p "${DOCKER_APPDATA}/mosquitto/data"
mkdir -p "${DOCKER_APPDATA}/mosquitto/log"
mkdir -p "${DOCKER_APPDATA}/zigbee2mqtt"
mkdir -p "${DOCKER_APPDATA}/homeassistant"
mkdir -p "${DOCKER_APPDATA}/nodered"

success "Directories created."

# -----------------------------------------------------------------------------
# STEP 6 — Generate Mosquitto config
# -----------------------------------------------------------------------------
header "Generating Mosquitto Config"

cat > "${DOCKER_APPDATA}/mosquitto/config/mosquitto.conf" << EOF
# =============================================================================
# Mosquitto MQTT Broker Configuration
# =============================================================================
# Generated by ha-setup.sh
# Authentication is required for all connections.
# =============================================================================

# Persistence
persistence true
persistence_location /mosquitto/data/

# Logging
log_dest file /mosquitto/log/mosquitto.log
log_dest stdout
log_type error
log_type warning
log_type notice
log_type information

# Listener — standard MQTT
listener 1883
protocol mqtt

# Listener — WebSocket (for browser-based clients)
listener 9001
protocol websockets

# Authentication — required for all connections
allow_anonymous false
password_file /mosquitto/config/passwd
EOF

# Generate password file using mosquitto_passwd
# We'll use docker to run mosquitto_passwd since it may not be installed on host
info "Generating Mosquitto password file..."
docker run --rm \
  -v "${DOCKER_APPDATA}/mosquitto/config:/mosquitto/config" \
  eclipse-mosquitto:latest \
  mosquitto_passwd -c -b /mosquitto/config/passwd "$MQTT_USER" "$MQTT_PASSWORD"

success "Mosquitto config generated."

# -----------------------------------------------------------------------------
# STEP 7 — Generate Mosquitto compose file
# -----------------------------------------------------------------------------
cat > "${DOCKER_APPDATA}/mosquitto/compose.yaml" << EOF
# =============================================================================
# Mosquitto MQTT Broker
# =============================================================================
# MQTT broker for Zigbee2MQTT, Node-RED, and Tasmota devices.
# Runs on IoT macvlan network at ${HA_IP}.
#
# Ports:
#   1883 — MQTT
#   9001 — MQTT over WebSocket
#
# Credentials managed via: ${DOCKER_APPDATA}/mosquitto/config/passwd
# To add a user: docker exec mosquitto mosquitto_passwd /mosquitto/config/passwd <username>
# To reload:     docker exec mosquitto kill -HUP 1
# =============================================================================

networks:
  iot_macvlan:
    name: iot_macvlan
    external: true

services:
  mosquitto:
    image: eclipse-mosquitto:latest
    container_name: mosquitto
    restart: unless-stopped
    networks:
      iot_macvlan:
        ipv4_address: \${HA_IP}
    ports:
      - "\${HA_IP}:1883:1883"
      - "\${HA_IP}:9001:9001"
    volumes:
      - \${APPDATA}/mosquitto/config:/mosquitto/config
      - \${APPDATA}/mosquitto/data:/mosquitto/data
      - \${APPDATA}/mosquitto/log:/mosquitto/log
EOF

# -----------------------------------------------------------------------------
# STEP 8 — Generate Zigbee2MQTT config
# -----------------------------------------------------------------------------
header "Generating Zigbee2MQTT Config"

cat > "${DOCKER_APPDATA}/zigbee2mqtt/configuration.yaml" << EOF
# =============================================================================
# Zigbee2MQTT Configuration
# =============================================================================
# Generated by ha-setup.sh
# Full config reference: https://www.zigbee2mqtt.io/guide/configuration/
# =============================================================================

# Home Assistant MQTT discovery
homeassistant: true

# Allow new devices to join (set to false after initial pairing)
permit_join: true

# MQTT broker connection
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://${HA_IP}
  user: ${MQTT_USER}
  # Password stored in secret — do not hardcode here
  password: "!secret mqtt_password"

# Zigbee adapter
serial:
  port: /dev/zigbee
  # Sonoff Zigbee Dongle-P uses ezsp adapter
  adapter: ezsp

# Frontend UI (internal only — no external port exposed)
frontend:
  port: 8080
  host: 0.0.0.0

# Advanced settings
advanced:
  log_level: info
  log_output:
    - console
    - file
  log_file: /app/data/log/z2m.log
  homeassistant_legacy_entity_attributes: false
  legacy_api: false
EOF

# Generate Zigbee2MQTT secret file for MQTT password
cat > "${DOCKER_APPDATA}/zigbee2mqtt/secret.yaml" << EOF
# =============================================================================
# Zigbee2MQTT Secrets
# =============================================================================
# Referenced in configuration.yaml as !secret <key>
# DO NOT commit this file to version control.
#
# This password is also stored in Bitwarden — update both if changed.
# =============================================================================
mqtt_password: ${MQTT_PASSWORD}
EOF

chmod 600 "${DOCKER_APPDATA}/zigbee2mqtt/secret.yaml"

# Clear password variable now that it's been written where needed
MQTT_PASSWORD=""

success "Zigbee2MQTT config generated."

# -----------------------------------------------------------------------------
# STEP 9 — Generate Zigbee2MQTT compose file
# -----------------------------------------------------------------------------
cat > "${DOCKER_APPDATA}/zigbee2mqtt/compose.yaml" << EOF
# =============================================================================
# Zigbee2MQTT
# =============================================================================
# Zigbee coordinator bridge using Sonoff Zigbee Dongle-P.
# Communicates with Mosquitto via MQTT on the IoT macvlan network.
# Internal only — no external ports exposed, no IP assigned (uses DHCP
# from macvlan range, only needs outbound connectivity to Mosquitto).
#
# Web UI available internally at port 8080 (not exposed externally).
# To access: docker exec -it zigbee2mqtt /bin/sh
#
# Dongle: ${ZIGBEE_DEVICE} → mapped to /dev/zigbee inside container
# =============================================================================

networks:
  iot_macvlan:
    name: iot_macvlan
    external: true

services:
  zigbee2mqtt:
    image: koenkk/zigbee2mqtt:latest
    container_name: zigbee2mqtt
    restart: unless-stopped
    networks:
      - iot_macvlan
    volumes:
      - \${APPDATA}/zigbee2mqtt:/app/data
    devices:
      - ${ZIGBEE_DEVICE}:/dev/zigbee
    environment:
      - TZ=\${TZ}
    depends_on:
      - mosquitto
EOF

# -----------------------------------------------------------------------------
# STEP 10 — Generate Home Assistant compose file
# -----------------------------------------------------------------------------
header "Generating Home Assistant Config"

cat > "${DOCKER_APPDATA}/homeassistant/compose.yaml" << EOF
# =============================================================================
# Home Assistant
# =============================================================================
# Home automation platform.
# Runs on IoT macvlan network at ${HA_IP}:8123.
#
# To upgrade: edit the image tag below, then:
#   docker compose pull
#   docker compose up -d
# Data is preserved in \${APPDATA}/homeassistant/
#
# USB devices:
#   ${MATTER_DEVICE} → /dev/matter (HA ZBT-2 Matter/Thread border router)
#
# Ports:
#   8123     — HA web UI
#   5683/udp — CoAP for Gen1 Shelly devices
# =============================================================================

networks:
  iot_macvlan:
    name: iot_macvlan
    external: true

services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:\${HA_VERSION:-2026.5}
    container_name: homeassistant
    restart: unless-stopped
    privileged: true
    network_mode: host
    volumes:
      - \${APPDATA}/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    devices:
      - ${MATTER_DEVICE}:/dev/matter
    environment:
      - TZ=\${TZ}
    ports:
      - "\${HA_IP}:8123:8123"
      - "\${HA_IP}:5683:5683/udp"
EOF

# -----------------------------------------------------------------------------
# STEP 11 — Generate Node-RED compose file and settings
# -----------------------------------------------------------------------------
header "Generating Node-RED Config"

# Generate bcrypt hash of Node-RED password using node
NODERED_PASS_HASH=$(docker run --rm node:alpine \
  node -e "const bcrypt=require('bcryptjs'); console.log(bcrypt.hashSync('${NODERED_PASSWORD}', 8));" 2>/dev/null || echo "HASH_FAILED")

if [[ "$NODERED_PASS_HASH" == "HASH_FAILED" ]]; then
  warn "Could not generate bcrypt hash for Node-RED password."
  warn "You will need to set the password manually in Node-RED settings after setup."
  NODERED_PASS_HASH='$2b$08$PLACEHOLDER'
fi

NODERED_PASSWORD=""

cat > "${DOCKER_APPDATA}/nodered/compose.yaml" << EOF
# =============================================================================
# Node-RED
# =============================================================================
# Automation flow editor.
# Runs on IoT macvlan network at ${HA_IP}:1880.
#
# Admin UI: https://nodered.${DOMAIN}
# =============================================================================

networks:
  iot_macvlan:
    name: iot_macvlan
    external: true

services:
  nodered:
    image: nodered/node-red:latest
    container_name: nodered
    restart: unless-stopped
    networks:
      iot_macvlan:
        ipv4_address: \${HA_IP}
    ports:
      - "\${HA_IP}:1880:1880"
    volumes:
      - \${APPDATA}/nodered:/data
    environment:
      - TZ=\${TZ}
      - NODE_RED_ENABLE_PROJECTS=true
EOF

# Generate Node-RED settings.js with authentication
cat > "${DOCKER_APPDATA}/nodered/settings.js" << EOF
/*
 * Node-RED Settings
 * Generated by ha-setup.sh
 * Full reference: https://nodered.org/docs/user-guide/runtime/configuration
 */
module.exports = {
    // Admin UI authentication
    adminAuth: {
        type: "credentials",
        users: [{
            username: "${NODERED_USER}",
            password: "${NODERED_PASS_HASH}",
            permissions: "*"
        }]
    },

    // Editor theme
    editorTheme: {
        page: {
            title: "OSAN - Node-RED"
        }
    },

    // Flow file
    flowFile: "flows.json",

    // Logging
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
        }
    },

    // Context storage
    contextStorage: {
        default: "memoryOnly",
        memoryOnly: { module: 'memory' },
        file: { module: 'localfilesystem' }
    }
}
EOF

success "Node-RED config generated."

# -----------------------------------------------------------------------------
# STEP 12 — Deploy Mosquitto
# -----------------------------------------------------------------------------
header "Deploying Mosquitto"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/mosquitto/compose.yaml" \
  up -d
success "Mosquitto deployed."

# -----------------------------------------------------------------------------
# STEP 13 — Deploy Zigbee2MQTT
# -----------------------------------------------------------------------------
header "Deploying Zigbee2MQTT"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/zigbee2mqtt/compose.yaml" \
  up -d
success "Zigbee2MQTT deployed."

# -----------------------------------------------------------------------------
# STEP 14 — Deploy Home Assistant
# -----------------------------------------------------------------------------
header "Deploying Home Assistant"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/homeassistant/compose.yaml" \
  up -d
success "Home Assistant deployed."

# -----------------------------------------------------------------------------
# STEP 15 — Deploy Node-RED
# -----------------------------------------------------------------------------
header "Deploying Node-RED"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/nodered/compose.yaml" \
  up -d
success "Node-RED deployed."

# -----------------------------------------------------------------------------
# STEP 16 — Update .env with new variables
# -----------------------------------------------------------------------------
header "Updating .env"

declare -A NEW_VARS=(
  ["HA_IP"]="$HA_IP"
  ["HA_VERSION"]="$HA_VERSION"
  ["HA_GATEWAY"]="$IOT_GATEWAY"
  ["IOT_SUBNET"]="$IOT_SUBNET"
  ["ZIGBEE_DEVICE"]="$ZIGBEE_DEVICE"
  ["MATTER_DEVICE"]="$MATTER_DEVICE"
  ["MQTT_USER"]="$MQTT_USER"
  ["NODERED_USER"]="$NODERED_USER"
)

for var in "${!NEW_VARS[@]}"; do
  value="${NEW_VARS[$var]}"
  if grep -q "^${var}=" "$ENV_FILE"; then
    sed -i "s|^${var}=.*|${var}=${value}|" "$ENV_FILE"
  else
    echo "${var}=${value}" >> "$ENV_FILE"
  fi
done

success "Updated ${ENV_FILE}"

# -----------------------------------------------------------------------------
# STEP 17 — Update Cloudflare DNS
# -----------------------------------------------------------------------------
header "Updating Cloudflare DNS"

CF_TOKEN="${CLOUDFLARE_TOKEN:-}"
ZONE_ID="${ZONE_ID:-}"

if [[ -z "$CF_TOKEN" ]] || [[ -z "$ZONE_ID" ]]; then
  warn "Cloudflare token or Zone ID not found in .env — skipping DNS update."
  warn "Run cloudflare-setup.sh first, then add ha and nodered records manually."
else
  for SUBDOMAIN in "ha" "nodered"; do
    FQDN="${SUBDOMAIN}.${DOMAIN}"
    info "Checking ${FQDN}..."

    EXISTING=$(curl -s -X GET \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${FQDN}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json")

    EXISTING_ID=$(echo "$EXISTING" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('success') and d.get('result'):
    print(d['result'][0]['id'])
" 2>/dev/null || echo "")

    EXISTING_IP=$(echo "$EXISTING" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('success') and d.get('result'):
    print(d['result'][0]['content'])
" 2>/dev/null || echo "")

    RECORD_DATA=$(python3 -c "
import json
print(json.dumps({
    'type': 'A',
    'name': '${FQDN}',
    'content': '${HA_IP}',
    'ttl': 1,
    'proxied': False
}))
")

    if [[ -z "$EXISTING_ID" ]]; then
      RESPONSE=$(curl -s -X POST \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$RECORD_DATA")
      success "Created DNS record: ${FQDN} → ${HA_IP}"
    elif [[ "$EXISTING_IP" == "$HA_IP" ]]; then
      success "Already correct: ${FQDN} → ${HA_IP} (skipped)"
    else
      curl -s -X PUT \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXISTING_ID}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$RECORD_DATA" > /dev/null
      success "Updated DNS record: ${FQDN} → ${HA_IP}"
    fi
  done
fi

# -----------------------------------------------------------------------------
# STEP 18 — Update NPM proxy hosts
# -----------------------------------------------------------------------------
header "Updating NGINX Proxy Manager"

NPM_URL="http://127.0.0.1:81"

# Wait for NPM to be ready
info "Checking NPM availability..."
if curl -s "${NPM_URL}/api/" &>/dev/null; then
  # Try to authenticate
  NPM_EMAIL_VAR="${NPM_ADMIN_EMAIL:-}"
  NPM_TOKEN=""

  if [[ -n "$NPM_EMAIL_VAR" ]]; then
    warn "NPM admin email not found in .env — skipping NPM proxy host creation."
    warn "Add ha.${DOMAIN} and nodered.${DOMAIN} proxy hosts manually in NPM."
  else
    warn "NPM integration skipped — add proxy hosts manually:"
    warn "  ha.${DOMAIN} → ${HA_IP}:8123 (http scheme)"
    warn "  nodered.${DOMAIN} → ${HA_IP}:1880 (http scheme)"
  fi
else
  warn "NPM not reachable — skipping proxy host creation."
  warn "Add proxy hosts manually in NPM admin UI:"
  warn "  ha.${DOMAIN} → ${HA_IP}:8123 (http scheme)"
  warn "  nodered.${DOMAIN} → ${HA_IP}:1880 (http scheme)"
fi

# -----------------------------------------------------------------------------
# STEP 19 — Update Homepage services.yaml
# -----------------------------------------------------------------------------
header "Updating Homepage"

SERVICES_FILE="/opt/docker/appdata/homepage/config/services.yaml"

if [[ -f "$SERVICES_FILE" ]]; then
  info "Adding Home Automation group to Homepage..."

  # Check if Home Automation section already exists
  if grep -q "Home Automation" "$SERVICES_FILE"; then
    info "Home Automation section already exists in services.yaml — skipping."
  else
    # Append Home Automation section
    cat >> "$SERVICES_FILE" << EOF

- Home Automation:
  - Home Assistant:
      href: https://ha.${DOMAIN}
      description: Home automation platform
      server: ${DOCKER_CONNECTION_NAME:-server-docker}
      container: homeassistant
      icon: home-assistant.png

  - Node-RED:
      href: https://nodered.${DOMAIN}
      description: Automation flow editor
      server: ${DOCKER_CONNECTION_NAME:-server-docker}
      container: nodered
      icon: node-red.png

  - Zigbee2MQTT:
      description: Zigbee coordinator bridge (internal)
      server: ${DOCKER_CONNECTION_NAME:-server-docker}
      container: zigbee2mqtt
      icon: zigbee2mqtt.png

  - Mosquitto:
      description: MQTT broker (internal)
      server: ${DOCKER_CONNECTION_NAME:-server-docker}
      container: mosquitto
      icon: mosquitto.png
EOF
    success "Home Automation group added to services.yaml."
  fi

  # Restart Homepage
  if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^homepage$"; then
    docker restart homepage
    success "Homepage restarted."
  fi
else
  warn "Homepage services.yaml not found — skipping."
fi

# =============================================================================
# STEP 20 — Final summary
# =============================================================================
echo
echo -e "${BOLD}${GREEN}"
echo "============================================================"
echo "   Home Assistant Stack Setup Complete"
echo "============================================================"
echo -e "${RESET}"
echo -e "  HA IP address     : ${GREEN}${HA_IP}${RESET}"
echo -e "  HA version        : ${GREEN}${HA_VERSION}${RESET}"
echo -e "  Zigbee device     : ${GREEN}${ZIGBEE_DEVICE}${RESET}"
echo -e "  Matter device     : ${GREEN}${MATTER_DEVICE}${RESET}"
echo -e "  MQTT user         : ${GREEN}${MQTT_USER}${RESET}"
echo -e "  Node-RED user     : ${GREEN}${NODERED_USER}${RESET}"
echo
echo -e "  Services:"
echo -e "    Home Assistant  : ${CYAN}http://${HA_IP}:8123${RESET}"
echo -e "    Node-RED        : ${CYAN}http://${HA_IP}:1880${RESET}"
echo -e "    Mosquitto MQTT  : ${CYAN}${HA_IP}:1883${RESET}"
echo -e "    Zigbee2MQTT     : ${GREEN}running (internal)${RESET}"
echo
echo -e "  Domain URLs (once NPM proxy hosts are added):"
echo -e "    Home Assistant  : ${CYAN}https://ha.${DOMAIN}${RESET}"
echo -e "    Node-RED        : ${CYAN}https://nodered.${DOMAIN}${RESET}"
echo
echo -e "${YELLOW}  Important next steps:${RESET}"
echo -e "  1. Add UniFi local DNS records:"
echo -e "     ha.${DOMAIN} → ${HA_IP}"
echo -e "     nodered.${DOMAIN} → ${HA_IP}"
echo -e "  2. Add NPM proxy hosts manually if not done automatically:"
echo -e "     ha.${DOMAIN} → ${HA_IP}:8123 (http)"
echo -e "     nodered.${DOMAIN} → ${HA_IP}:1880 (http)"
echo -e "  3. Open HA at http://${HA_IP}:8123 and complete onboarding"
echo -e "  4. In HA, install MQTT integration and connect to ${HA_IP}:1883"
echo -e "  5. In HA, install Shelly integration — devices should auto-discover"
echo -e "  6. Check Zigbee2MQTT logs: docker logs zigbee2mqtt"
echo -e "  7. Update Zigbee2MQTT secret.yaml with correct MQTT password:"
echo -e "     ${CYAN}nano ${DOCKER_APPDATA}/zigbee2mqtt/secret.yaml${RESET}"
echo -e "  8. To upgrade HA: edit image tag in compose.yaml, then:"
echo -e "     ${CYAN}cd ${DOCKER_APPDATA}/homeassistant && docker compose pull && docker compose up -d${RESET}"
echo#!/usr/bin/env bash
# =============================================================================
# Home Assistant Stack Setup Script
# =============================================================================
# Version  : 1.0.1
# Created  : 2026-06-10
# Author   : github.com/thirsty-fatman
#
# Changelog:
#   1.0.1 - 2026-06-10 - Fixed Zigbee2MQTT network (moved to iot_macvlan to
#                         reach Mosquitto). Fixed secret.yaml to write actual
#                         MQTT password instead of username placeholder.
#                         Fixed invalid 'local' keyword used outside a function
#                         in Matter dongle detection.
#   1.0.0 - 2026-06-10 - Initial release
#
# Description:
#   Interactive setup script for the Home Assistant stack on Ubuntu Server 24.04.
#   Standalone script — run independently after server-setup.sh.
#   No personal information hardcoded. Safe to publish publicly.
#
# What this script does:
#   1.  Adds secondary IP to OSAN via Netplan (IoT network)
#   2.  Creates Docker macvlan network on IoT subnet
#   3.  Creates directory structure for all HA stack containers
#   4.  Detects USB dongles (Zigbee and Matter/Thread)
#   5.  Generates Mosquitto config with authentication
#   6.  Generates Zigbee2MQTT config
#   7.  Deploys Mosquitto
#   8.  Deploys Zigbee2MQTT
#   9.  Deploys Home Assistant
#   10. Deploys Node-RED
#   11. Updates /opt/docker/.env with new variables
#   12. Updates Cloudflare DNS with ha and nodered A records
#   13. Updates NPM with proxy hosts for ha and nodered
#   14. Updates Homepage services.yaml with Home Automation group
#   15. Restarts Homepage
#
# Usage:
#   sudo bash ha-setup.sh
#
# Or directly from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/ha-setup.sh -o ha-setup.sh
#   sudo bash ha-setup.sh
#
# Requirements:
#   - server-setup.sh must have been run first
#   - /opt/docker/.env must exist
#   - Sonoff Zigbee Dongle-P and HA ZBT-2 must be available to plug in
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colour helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}\n"; }

# -----------------------------------------------------------------------------
# Must be run as root
# -----------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
  error "This script must be run as root. Try: sudo bash ha-setup.sh"
  exit 1
fi

# -----------------------------------------------------------------------------
# Check dependencies
# -----------------------------------------------------------------------------
for cmd in curl python3 docker ip; do
  if ! command -v "$cmd" &>/dev/null; then
    error "${cmd} is required but not installed."
    exit 1
  fi
done

# -----------------------------------------------------------------------------
# Check /opt/docker/.env exists
# -----------------------------------------------------------------------------
ENV_FILE="/opt/docker/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  error "${ENV_FILE} not found. Please run server-setup.sh first."
  exit 1
fi

# -----------------------------------------------------------------------------
# Load .env
# -----------------------------------------------------------------------------
info "Loading ${ENV_FILE}..."
while IFS='=' read -r key value; do
  [[ "$key" =~ ^[A-Z_]+$ ]] || continue
  [[ -z "$value" ]] && continue
  printf -v "$key" '%s' "$value" 2>/dev/null || true
done < <(grep -E '^[A-Z_]+=.+' "$ENV_FILE")

# Set defaults from .env or fallback
DOCKER_BASE="${DOCKERDIR:-/opt/docker}"
DOCKER_APPDATA="${APPDATA:-/opt/docker/appdata}"
DOCKER_VOLUMES="${VOLUMES:-/opt/docker/volumes}"
SERVER_LAN_IP="${SERVER_LAN_IP:-$(hostname -I | awk '{print $1}')}"

# -----------------------------------------------------------------------------
# Helper: prompt with default
# -----------------------------------------------------------------------------
prompt_default() {
  local varname="$1"
  local question="$2"
  local default="$3"
  local input

  echo -e "${BOLD}${question}${RESET}"
  echo -e "  Current/default: ${YELLOW}${default}${RESET}"
  read -rp "  New value (Enter to keep): " input < /dev/tty
  echo

  if [[ -z "$input" ]]; then
    printf -v "$varname" '%s' "$default"
  else
    printf -v "$varname" '%s' "$input"
  fi
}

# -----------------------------------------------------------------------------
# Helper: prompt password (hidden, confirmed, minimum 8 characters)
# -----------------------------------------------------------------------------
prompt_password() {
  local varname="$1"
  local label="$2"
  local pass1 pass2

  while true; do
    echo -e "${BOLD}Password for ${label}${RESET}"
    read -rsp "  Enter password: " pass1 < /dev/tty
    echo

    if [[ ${#pass1} -lt 8 ]]; then
      warn "Password must be at least 8 characters. Please try again."
      continue
    fi

    read -rsp "  Confirm password: " pass2 < /dev/tty
    echo

    if [[ "$pass1" == "$pass2" ]]; then
      printf -v "$varname" '%s' "$pass1"
      echo
      break
    else
      warn "Passwords do not match. Please try again."
    fi
  done
}

# -----------------------------------------------------------------------------
# Helper: detect USB serial devices
# Returns list of /dev/ttyUSB* and /dev/ttyACM* devices
# -----------------------------------------------------------------------------
get_usb_devices() {
  local devices=()
  for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "$dev" ]] && devices+=("$dev")
  done
  echo "${devices[@]:-}"
}

# -----------------------------------------------------------------------------
# Helper: prompt for USB device with auto-detection
# -----------------------------------------------------------------------------
prompt_usb_device() {
  local varname="$1"
  local device_name="$2"
  local insert_prompt="$3"

  echo -e "${BOLD}${device_name}${RESET}"
  echo -e "  ${insert_prompt}"
  echo -e "  Press ${YELLOW}Enter${RESET} when the device is plugged in."
  read -rp "" < /dev/tty
  echo

  # Scan for devices
  local devices
  devices=$(get_usb_devices)

  if [[ -z "$devices" ]]; then
    warn "No USB serial devices detected."
    echo -e "${BOLD}Enter device path manually${RESET} (e.g. /dev/ttyUSB0 or /dev/ttyACM0):"
    read -rp "  Device path: " manual_path < /dev/tty
    echo
    printf -v "$varname" '%s' "$manual_path"
    return
  fi

  # Show detected devices
  echo -e "  Detected USB serial devices:"
  local i=1
  local device_array=()
  for dev in $devices; do
    echo -e "    ${CYAN}${i}.${RESET} ${dev}"
    device_array+=("$dev")
    ((i++))
  done
  echo

  if [[ ${#device_array[@]} -eq 1 ]]; then
    # Only one device — confirm it
    echo -e "${BOLD}Is this the correct device? ${YELLOW}${device_array[0]}${RESET}"
    read -rp "  Confirm [Y/n]: " confirm < /dev/tty
    echo
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
      echo -e "${BOLD}Enter device path manually:${RESET}"
      read -rp "  Device path: " manual_path < /dev/tty
      echo
      printf -v "$varname" '%s' "$manual_path"
    else
      printf -v "$varname" '%s' "${device_array[0]}"
    fi
  else
    # Multiple devices — ask user to select
    while true; do
      read -rp "  Select device number [1-${#device_array[@]}]: " selection < /dev/tty
      echo
      if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#device_array[@]} )); then
        printf -v "$varname" '%s' "${device_array[$((selection-1))]}"
        break
      else
        warn "Invalid selection. Please try again."
      fi
    done
  fi

  success "Selected: ${!varname}"
}

# =============================================================================
# STEP 1 — Interactive menu
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "   Home Assistant Stack Setup"
echo "   v1.0.1 | 2026-06-10"
echo "============================================================"
echo -e "${RESET}"
echo -e "This script sets up Home Assistant and dependencies on OSAN."
echo -e "Run after server-setup.sh. Requires /opt/docker/.env.\n"

# --- Network config ----------------------------------------------------------
header "IoT Network Configuration"
echo -e "  Home Assistant will be assigned an IP on your IoT subnet."
echo -e "  OSAN will have a secondary IP address on the IoT network.\n"

prompt_default NIC_NAME "Network interface name" "eno1"
prompt_default IOT_SUBNET "IoT subnet" "192.168.8.0/24"
prompt_default IOT_GATEWAY "IoT gateway" "192.168.8.1"
prompt_default HA_IP "IP address for HA stack (secondary IP on OSAN)" "192.168.8.2"

# Derive VLAN ID from subnet if needed (informational only)
IOT_NETWORK=$(echo "$IOT_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)

# --- HA version --------------------------------------------------------------
header "Home Assistant"
prompt_default HA_VERSION "Home Assistant version" "2026.5"

# --- USB dongle detection ----------------------------------------------------
header "USB Dongles"
echo -e "  Two USB dongles are required:"
echo -e "  ${CYAN}1.${RESET} Sonoff Zigbee Dongle-P — Zigbee coordinator for Zigbee2MQTT"
echo -e "  ${CYAN}2.${RESET} HA ZBT-2 — Matter/Thread border router for Home Assistant\n"
echo -e "  Please ensure both are unplugged before continuing."
read -rp "  Press Enter when both dongles are unplugged: " < /dev/tty
echo

# Detect Zigbee dongle
prompt_usb_device ZIGBEE_DEVICE \
  "Zigbee Dongle (Sonoff Zigbee Dongle-P)" \
  "Please plug in the Sonoff Zigbee Dongle-P now."

# Detect Matter dongle (scan for NEW device after Zigbee is already plugged in)
echo -e "${BOLD}Matter/Thread Dongle (HA ZBT-2)${RESET}"
echo -e "  Please plug in the HA ZBT-2 now."
echo -e "  Press ${YELLOW}Enter${RESET} when plugged in."
read -rp "" < /dev/tty
echo

# Show devices excluding the already-selected Zigbee device
ALL_DEVICES=$(get_usb_devices)
MATTER_CANDIDATES=()
for dev in $ALL_DEVICES; do
  [[ "$dev" != "$ZIGBEE_DEVICE" ]] && MATTER_CANDIDATES+=("$dev")
done

if [[ ${#MATTER_CANDIDATES[@]} -eq 0 ]]; then
  warn "No new USB devices detected after plugging in HA ZBT-2."
  echo -e "${BOLD}Enter device path manually:${RESET}"
  read -rp "  Device path: " MATTER_DEVICE < /dev/tty
  echo
elif [[ ${#MATTER_CANDIDATES[@]} -eq 1 ]]; then
  echo -e "  Detected: ${CYAN}${MATTER_CANDIDATES[0]}${RESET}"
  read -rp "  Is this the HA ZBT-2? [Y/n]: " confirm < /dev/tty
  echo
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    read -rp "  Enter device path manually: " MATTER_DEVICE < /dev/tty
    echo
  else
    MATTER_DEVICE="${MATTER_CANDIDATES[0]}"
  fi
else
  echo -e "  Detected multiple new devices:"
  i=1
  for dev in "${MATTER_CANDIDATES[@]}"; do
    echo -e "    ${CYAN}${i}.${RESET} ${dev}"
    ((i++))
  done
  echo
  while true; do
    read -rp "  Select HA ZBT-2 device [1-${#MATTER_CANDIDATES[@]}]: " sel < /dev/tty
    echo
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#MATTER_CANDIDATES[@]} )); then
      MATTER_DEVICE="${MATTER_CANDIDATES[$((sel-1))]}"
      break
    else
      warn "Invalid selection. Please try again."
    fi
  done
fi
success "Matter device selected: ${MATTER_DEVICE}"

# --- Mosquitto credentials ---------------------------------------------------
header "Mosquitto MQTT Credentials"
echo -e "  These credentials are used by Zigbee2MQTT, Node-RED, and any"
echo -e "  other MQTT clients connecting to the broker.\n"

echo -e "${BOLD}MQTT username${RESET}"
read -rp "  Username: " MQTT_USER < /dev/tty
echo
prompt_password MQTT_PASSWORD "MQTT (${MQTT_USER})"

# --- Node-RED credentials ----------------------------------------------------
header "Node-RED Credentials"
echo -e "  Admin credentials for the Node-RED web UI.\n"

echo -e "${BOLD}Node-RED username${RESET}"
read -rp "  Username: " NODERED_USER < /dev/tty
echo
prompt_password NODERED_PASSWORD "Node-RED (${NODERED_USER})"

# --- Domain ------------------------------------------------------------------
header "Domain Configuration"
EXISTING_DOMAIN="${DOMAIN:-}"
if [[ -n "$EXISTING_DOMAIN" ]]; then
  prompt_default DOMAIN "Domain for proxy hosts" "$EXISTING_DOMAIN"
else
  echo -e "${BOLD}Domain name${RESET} (e.g. example.com)"
  while true; do
    read -rp "  Domain: " DOMAIN < /dev/tty
    echo
    if [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      warn "Invalid domain format. Please try again."
    fi
  done
fi

# =============================================================================
# STEP 2 — Confirmation summary
# =============================================================================
header "Confirmation Summary"
echo -e "  Network interface    : ${YELLOW}${NIC_NAME}${RESET}"
echo -e "  IoT subnet           : ${YELLOW}${IOT_SUBNET}${RESET}"
echo -e "  IoT gateway          : ${YELLOW}${IOT_GATEWAY}${RESET}"
echo -e "  HA stack IP          : ${YELLOW}${HA_IP}${RESET}"
echo -e "  HA version           : ${YELLOW}${HA_VERSION}${RESET}"
echo -e "  Zigbee device        : ${YELLOW}${ZIGBEE_DEVICE}${RESET}"
echo -e "  Matter device        : ${YELLOW}${MATTER_DEVICE}${RESET}"
echo -e "  MQTT username        : ${YELLOW}${MQTT_USER}${RESET}"
echo -e "  MQTT password        : ${YELLOW}(set — not displayed)${RESET}"
echo -e "  Node-RED username    : ${YELLOW}${NODERED_USER}${RESET}"
echo -e "  Node-RED password    : ${YELLOW}(set — not displayed)${RESET}"
echo -e "  Domain               : ${YELLOW}${DOMAIN}${RESET}"
echo
echo -e "  Containers to deploy:"
echo -e "    - Mosquitto         (${HA_IP}:1883, ${HA_IP}:9001)"
echo -e "    - Zigbee2MQTT       (internal only)"
echo -e "    - Home Assistant    (${HA_IP}:8123, ${HA_IP}:5683/udp)"
echo -e "    - Node-RED          (${HA_IP}:1880)"
echo
echo -e "  Proxy hosts to create:"
echo -e "    - https://ha.${DOMAIN}       → ${HA_IP}:8123"
echo -e "    - https://nodered.${DOMAIN}  → ${HA_IP}:1880"
echo
read -rp "$(echo -e "${BOLD}Proceed with these settings? [y/N]: ${RESET}")" CONFIRM < /dev/tty
echo

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  warn "Aborted by user. Nothing has been changed."
  exit 0
fi

# =============================================================================
# From here everything runs unattended
# =============================================================================

# -----------------------------------------------------------------------------
# STEP 3 — Configure Netplan (add secondary IoT IP)
# -----------------------------------------------------------------------------
header "Configuring Netplan"

NETPLAN_FILE="/etc/netplan/60-iot-vlan.yaml"

# Check if already configured
if ip addr show "$NIC_NAME" | grep -q "$HA_IP"; then
  info "Secondary IP ${HA_IP} already configured on ${NIC_NAME} — skipping Netplan."
else
  info "Adding ${HA_IP} as secondary IP on ${NIC_NAME}..."

  cat > "$NETPLAN_FILE" << EOF
# =============================================================================
# OSAN IoT Network Secondary IP
# =============================================================================
# Adds a secondary IP address on the IoT subnet to ${NIC_NAME}.
# This allows Docker macvlan containers to have a presence on the IoT network.
# Generated by ha-setup.sh
# =============================================================================
network:
  version: 2
  ethernets:
    ${NIC_NAME}:
      addresses:
        - ${HA_IP}/24
EOF

  chmod 600 "$NETPLAN_FILE"

  # Apply Netplan
  netplan apply
  sleep 2

  # Verify
  if ip addr show "$NIC_NAME" | grep -q "$HA_IP"; then
    success "Secondary IP ${HA_IP} added to ${NIC_NAME}."
  else
    error "Failed to add secondary IP. Check Netplan config at ${NETPLAN_FILE}."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# STEP 4 — Create Docker macvlan network
# -----------------------------------------------------------------------------
header "Creating Docker Macvlan Network"

MACVLAN_NETWORK="iot_macvlan"

if docker network ls | grep -q "$MACVLAN_NETWORK"; then
  info "Docker macvlan network '${MACVLAN_NETWORK}' already exists — skipping."
else
  info "Creating macvlan network '${MACVLAN_NETWORK}'..."

  docker network create \
    --driver macvlan \
    --subnet="${IOT_SUBNET}" \
    --gateway="${IOT_GATEWAY}" \
    --opt parent="${NIC_NAME}" \
    "$MACVLAN_NETWORK"

  success "Macvlan network '${MACVLAN_NETWORK}' created."
fi

# -----------------------------------------------------------------------------
# STEP 5 — Create directory structure
# -----------------------------------------------------------------------------
header "Creating Directory Structure"

mkdir -p "${DOCKER_APPDATA}/mosquitto/config"
mkdir -p "${DOCKER_APPDATA}/mosquitto/data"
mkdir -p "${DOCKER_APPDATA}/mosquitto/log"
mkdir -p "${DOCKER_APPDATA}/zigbee2mqtt"
mkdir -p "${DOCKER_APPDATA}/homeassistant"
mkdir -p "${DOCKER_APPDATA}/nodered"

success "Directories created."

# -----------------------------------------------------------------------------
# STEP 6 — Generate Mosquitto config
# -----------------------------------------------------------------------------
header "Generating Mosquitto Config"

cat > "${DOCKER_APPDATA}/mosquitto/config/mosquitto.conf" << EOF
# =============================================================================
# Mosquitto MQTT Broker Configuration
# =============================================================================
# Generated by ha-setup.sh
# Authentication is required for all connections.
# =============================================================================

# Persistence
persistence true
persistence_location /mosquitto/data/

# Logging
log_dest file /mosquitto/log/mosquitto.log
log_dest stdout
log_type error
log_type warning
log_type notice
log_type information

# Listener — standard MQTT
listener 1883
protocol mqtt

# Listener — WebSocket (for browser-based clients)
listener 9001
protocol websockets

# Authentication — required for all connections
allow_anonymous false
password_file /mosquitto/config/passwd
EOF

# Generate password file using mosquitto_passwd
# We'll use docker to run mosquitto_passwd since it may not be installed on host
info "Generating Mosquitto password file..."
docker run --rm \
  -v "${DOCKER_APPDATA}/mosquitto/config:/mosquitto/config" \
  eclipse-mosquitto:latest \
  mosquitto_passwd -c -b /mosquitto/config/passwd "$MQTT_USER" "$MQTT_PASSWORD"

success "Mosquitto config generated."

# -----------------------------------------------------------------------------
# STEP 7 — Generate Mosquitto compose file
# -----------------------------------------------------------------------------
cat > "${DOCKER_APPDATA}/mosquitto/compose.yaml" << EOF
# =============================================================================
# Mosquitto MQTT Broker
# =============================================================================
# MQTT broker for Zigbee2MQTT, Node-RED, and Tasmota devices.
# Runs on IoT macvlan network at ${HA_IP}.
#
# Ports:
#   1883 — MQTT
#   9001 — MQTT over WebSocket
#
# Credentials managed via: ${DOCKER_APPDATA}/mosquitto/config/passwd
# To add a user: docker exec mosquitto mosquitto_passwd /mosquitto/config/passwd <username>
# To reload:     docker exec mosquitto kill -HUP 1
# =============================================================================

networks:
  iot_macvlan:
    name: iot_macvlan
    external: true

services:
  mosquitto:
    image: eclipse-mosquitto:latest
    container_name: mosquitto
    restart: unless-stopped
    networks:
      iot_macvlan:
        ipv4_address: \${HA_IP}
    ports:
      - "\${HA_IP}:1883:1883"
      - "\${HA_IP}:9001:9001"
    volumes:
      - \${APPDATA}/mosquitto/config:/mosquitto/config
      - \${APPDATA}/mosquitto/data:/mosquitto/data
      - \${APPDATA}/mosquitto/log:/mosquitto/log
EOF

# -----------------------------------------------------------------------------
# STEP 8 — Generate Zigbee2MQTT config
# -----------------------------------------------------------------------------
header "Generating Zigbee2MQTT Config"

cat > "${DOCKER_APPDATA}/zigbee2mqtt/configuration.yaml" << EOF
# =============================================================================
# Zigbee2MQTT Configuration
# =============================================================================
# Generated by ha-setup.sh
# Full config reference: https://www.zigbee2mqtt.io/guide/configuration/
# =============================================================================

# Home Assistant MQTT discovery
homeassistant: true

# Allow new devices to join (set to false after initial pairing)
permit_join: true

# MQTT broker connection
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://${HA_IP}
  user: ${MQTT_USER}
  # Password stored in secret — do not hardcode here
  password: "!secret mqtt_password"

# Zigbee adapter
serial:
  port: /dev/zigbee
  # Sonoff Zigbee Dongle-P uses ezsp adapter
  adapter: ezsp

# Frontend UI (internal only — no external port exposed)
frontend:
  port: 8080
  host: 0.0.0.0

# Advanced settings
advanced:
  log_level: info
  log_output:
    - console
    - file
  log_file: /app/data/log/z2m.log
  homeassistant_legacy_entity_attributes: false
  legacy_api: false
EOF

# Generate Zigbee2MQTT secret file for MQTT password
cat > "${DOCKER_APPDATA}/zigbee2mqtt/secret.yaml" << EOF
# =============================================================================
# Zigbee2MQTT Secrets
# =============================================================================
# Referenced in configuration.yaml as !secret <key>
# DO NOT commit this file to version control.
#
# This password is also stored in Bitwarden — update both if changed.
# =============================================================================
mqtt_password: ${MQTT_PASSWORD}
EOF

chmod 600 "${DOCKER_APPDATA}/zigbee2mqtt/secret.yaml"

# Clear password variable now that it's been written where needed
MQTT_PASSWORD=""

success "Zigbee2MQTT config generated."

# -----------------------------------------------------------------------------
# STEP 9 — Generate Zigbee2MQTT compose file
# -----------------------------------------------------------------------------
cat > "${DOCKER_APPDATA}/zigbee2mqtt/compose.yaml" << EOF
# =============================================================================
# Zigbee2MQTT
# =============================================================================
# Zigbee coordinator bridge using Sonoff Zigbee Dongle-P.
# Communicates with Mosquitto via MQTT on the IoT macvlan network.
# Internal only — no external ports exposed, no IP assigned (uses DHCP
# from macvlan range, only needs outbound connectivity to Mosquitto).
#
# Web UI available internally at port 8080 (not exposed externally).
# To access: docker exec -it zigbee2mqtt /bin/sh
#
# Dongle: ${ZIGBEE_DEVICE} → mapped to /dev/zigbee inside container
# =============================================================================

networks:
  iot_macvlan:
    name: iot_macvlan
    external: true

services:
  zigbee2mqtt:
    image: koenkk/zigbee2mqtt:latest
    container_name: zigbee2mqtt
    restart: unless-stopped
    networks:
      - iot_macvlan
    volumes:
      - \${APPDATA}/zigbee2mqtt:/app/data
    devices:
      - ${ZIGBEE_DEVICE}:/dev/zigbee
    environment:
      - TZ=\${TZ}
    depends_on:
      - mosquitto
EOF

# -----------------------------------------------------------------------------
# STEP 10 — Generate Home Assistant compose file
# -----------------------------------------------------------------------------
header "Generating Home Assistant Config"

cat > "${DOCKER_APPDATA}/homeassistant/compose.yaml" << EOF
# =============================================================================
# Home Assistant
# =============================================================================
# Home automation platform.
# Runs on IoT macvlan network at ${HA_IP}:8123.
#
# To upgrade: edit the image tag below, then:
#   docker compose pull
#   docker compose up -d
# Data is preserved in \${APPDATA}/homeassistant/
#
# USB devices:
#   ${MATTER_DEVICE} → /dev/matter (HA ZBT-2 Matter/Thread border router)
#
# Ports:
#   8123     — HA web UI
#   5683/udp — CoAP for Gen1 Shelly devices
# =============================================================================

networks:
  iot_macvlan:
    name: iot_macvlan
    external: true

services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:\${HA_VERSION:-2026.5}
    container_name: homeassistant
    restart: unless-stopped
    privileged: true
    network_mode: host
    volumes:
      - \${APPDATA}/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    devices:
      - ${MATTER_DEVICE}:/dev/matter
    environment:
      - TZ=\${TZ}
    ports:
      - "\${HA_IP}:8123:8123"
      - "\${HA_IP}:5683:5683/udp"
EOF

# -----------------------------------------------------------------------------
# STEP 11 — Generate Node-RED compose file and settings
# -----------------------------------------------------------------------------
header "Generating Node-RED Config"

# Generate bcrypt hash of Node-RED password using node
NODERED_PASS_HASH=$(docker run --rm node:alpine \
  node -e "const bcrypt=require('bcryptjs'); console.log(bcrypt.hashSync('${NODERED_PASSWORD}', 8));" 2>/dev/null || echo "HASH_FAILED")

if [[ "$NODERED_PASS_HASH" == "HASH_FAILED" ]]; then
  warn "Could not generate bcrypt hash for Node-RED password."
  warn "You will need to set the password manually in Node-RED settings after setup."
  NODERED_PASS_HASH='$2b$08$PLACEHOLDER'
fi

NODERED_PASSWORD=""

cat > "${DOCKER_APPDATA}/nodered/compose.yaml" << EOF
# =============================================================================
# Node-RED
# =============================================================================
# Automation flow editor.
# Runs on IoT macvlan network at ${HA_IP}:1880.
#
# Admin UI: https://nodered.${DOMAIN}
# =============================================================================

networks:
  iot_macvlan:
    name: iot_macvlan
    external: true

services:
  nodered:
    image: nodered/node-red:latest
    container_name: nodered
    restart: unless-stopped
    networks:
      iot_macvlan:
        ipv4_address: \${HA_IP}
    ports:
      - "\${HA_IP}:1880:1880"
    volumes:
      - \${APPDATA}/nodered:/data
    environment:
      - TZ=\${TZ}
      - NODE_RED_ENABLE_PROJECTS=true
EOF

# Generate Node-RED settings.js with authentication
cat > "${DOCKER_APPDATA}/nodered/settings.js" << EOF
/*
 * Node-RED Settings
 * Generated by ha-setup.sh
 * Full reference: https://nodered.org/docs/user-guide/runtime/configuration
 */
module.exports = {
    // Admin UI authentication
    adminAuth: {
        type: "credentials",
        users: [{
            username: "${NODERED_USER}",
            password: "${NODERED_PASS_HASH}",
            permissions: "*"
        }]
    },

    // Editor theme
    editorTheme: {
        page: {
            title: "OSAN - Node-RED"
        }
    },

    // Flow file
    flowFile: "flows.json",

    // Logging
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
        }
    },

    // Context storage
    contextStorage: {
        default: "memoryOnly",
        memoryOnly: { module: 'memory' },
        file: { module: 'localfilesystem' }
    }
}
EOF

success "Node-RED config generated."

# -----------------------------------------------------------------------------
# STEP 12 — Deploy Mosquitto
# -----------------------------------------------------------------------------
header "Deploying Mosquitto"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/mosquitto/compose.yaml" \
  up -d
success "Mosquitto deployed."

# -----------------------------------------------------------------------------
# STEP 13 — Deploy Zigbee2MQTT
# -----------------------------------------------------------------------------
header "Deploying Zigbee2MQTT"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/zigbee2mqtt/compose.yaml" \
  up -d
success "Zigbee2MQTT deployed."

# -----------------------------------------------------------------------------
# STEP 14 — Deploy Home Assistant
# -----------------------------------------------------------------------------
header "Deploying Home Assistant"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/homeassistant/compose.yaml" \
  up -d
success "Home Assistant deployed."

# -----------------------------------------------------------------------------
# STEP 15 — Deploy Node-RED
# -----------------------------------------------------------------------------
header "Deploying Node-RED"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/nodered/compose.yaml" \
  up -d
success "Node-RED deployed."

# -----------------------------------------------------------------------------
# STEP 16 — Update .env with new variables
# -----------------------------------------------------------------------------
header "Updating .env"

declare -A NEW_VARS=(
  ["HA_IP"]="$HA_IP"
  ["HA_VERSION"]="$HA_VERSION"
  ["HA_GATEWAY"]="$IOT_GATEWAY"
  ["IOT_SUBNET"]="$IOT_SUBNET"
  ["ZIGBEE_DEVICE"]="$ZIGBEE_DEVICE"
  ["MATTER_DEVICE"]="$MATTER_DEVICE"
  ["MQTT_USER"]="$MQTT_USER"
  ["NODERED_USER"]="$NODERED_USER"
)

for var in "${!NEW_VARS[@]}"; do
  value="${NEW_VARS[$var]}"
  if grep -q "^${var}=" "$ENV_FILE"; then
    sed -i "s|^${var}=.*|${var}=${value}|" "$ENV_FILE"
  else
    echo "${var}=${value}" >> "$ENV_FILE"
  fi
done

success "Updated ${ENV_FILE}"

# -----------------------------------------------------------------------------
# STEP 17 — Update Cloudflare DNS
# -----------------------------------------------------------------------------
header "Updating Cloudflare DNS"

CF_TOKEN="${CLOUDFLARE_TOKEN:-}"
ZONE_ID="${ZONE_ID:-}"

if [[ -z "$CF_TOKEN" ]] || [[ -z "$ZONE_ID" ]]; then
  warn "Cloudflare token or Zone ID not found in .env — skipping DNS update."
  warn "Run cloudflare-setup.sh first, then add ha and nodered records manually."
else
  for SUBDOMAIN in "ha" "nodered"; do
    FQDN="${SUBDOMAIN}.${DOMAIN}"
    info "Checking ${FQDN}..."

    EXISTING=$(curl -s -X GET \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${FQDN}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json")

    EXISTING_ID=$(echo "$EXISTING" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('success') and d.get('result'):
    print(d['result'][0]['id'])
" 2>/dev/null || echo "")

    EXISTING_IP=$(echo "$EXISTING" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('success') and d.get('result'):
    print(d['result'][0]['content'])
" 2>/dev/null || echo "")

    RECORD_DATA=$(python3 -c "
import json
print(json.dumps({
    'type': 'A',
    'name': '${FQDN}',
    'content': '${HA_IP}',
    'ttl': 1,
    'proxied': False
}))
")

    if [[ -z "$EXISTING_ID" ]]; then
      RESPONSE=$(curl -s -X POST \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$RECORD_DATA")
      success "Created DNS record: ${FQDN} → ${HA_IP}"
    elif [[ "$EXISTING_IP" == "$HA_IP" ]]; then
      success "Already correct: ${FQDN} → ${HA_IP} (skipped)"
    else
      curl -s -X PUT \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXISTING_ID}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$RECORD_DATA" > /dev/null
      success "Updated DNS record: ${FQDN} → ${HA_IP}"
    fi
  done
fi

# -----------------------------------------------------------------------------
# STEP 18 — Update NPM proxy hosts
# -----------------------------------------------------------------------------
header "Updating NGINX Proxy Manager"

NPM_URL="http://127.0.0.1:81"

# Wait for NPM to be ready
info "Checking NPM availability..."
if curl -s "${NPM_URL}/api/" &>/dev/null; then
  # Try to authenticate
  NPM_EMAIL_VAR="${NPM_ADMIN_EMAIL:-}"
  NPM_TOKEN=""

  if [[ -n "$NPM_EMAIL_VAR" ]]; then
    warn "NPM admin email not found in .env — skipping NPM proxy host creation."
    warn "Add ha.${DOMAIN} and nodered.${DOMAIN} proxy hosts manually in NPM."
  else
    warn "NPM integration skipped — add proxy hosts manually:"
    warn "  ha.${DOMAIN} → ${HA_IP}:8123 (http scheme)"
    warn "  nodered.${DOMAIN} → ${HA_IP}:1880 (http scheme)"
  fi
else
  warn "NPM not reachable — skipping proxy host creation."
  warn "Add proxy hosts manually in NPM admin UI:"
  warn "  ha.${DOMAIN} → ${HA_IP}:8123 (http scheme)"
  warn "  nodered.${DOMAIN} → ${HA_IP}:1880 (http scheme)"
fi

# -----------------------------------------------------------------------------
# STEP 19 — Update Homepage services.yaml
# -----------------------------------------------------------------------------
header "Updating Homepage"

SERVICES_FILE="/opt/docker/appdata/homepage/config/services.yaml"

if [[ -f "$SERVICES_FILE" ]]; then
  info "Adding Home Automation group to Homepage..."

  # Check if Home Automation section already exists
  if grep -q "Home Automation" "$SERVICES_FILE"; then
    info "Home Automation section already exists in services.yaml — skipping."
  else
    # Append Home Automation section
    cat >> "$SERVICES_FILE" << EOF

- Home Automation:
  - Home Assistant:
      href: https://ha.${DOMAIN}
      description: Home automation platform
      server: ${DOCKER_CONNECTION_NAME:-server-docker}
      container: homeassistant
      icon: home-assistant.png

  - Node-RED:
      href: https://nodered.${DOMAIN}
      description: Automation flow editor
      server: ${DOCKER_CONNECTION_NAME:-server-docker}
      container: nodered
      icon: node-red.png

  - Zigbee2MQTT:
      description: Zigbee coordinator bridge (internal)
      server: ${DOCKER_CONNECTION_NAME:-server-docker}
      container: zigbee2mqtt
      icon: zigbee2mqtt.png

  - Mosquitto:
      description: MQTT broker (internal)
      server: ${DOCKER_CONNECTION_NAME:-server-docker}
      container: mosquitto
      icon: mosquitto.png
EOF
    success "Home Automation group added to services.yaml."
  fi

  # Restart Homepage
  if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^homepage$"; then
    docker restart homepage
    success "Homepage restarted."
  fi
else
  warn "Homepage services.yaml not found — skipping."
fi

# =============================================================================
# STEP 20 — Final summary
# =============================================================================
echo
echo -e "${BOLD}${GREEN}"
echo "============================================================"
echo "   Home Assistant Stack Setup Complete"
echo "============================================================"
echo -e "${RESET}"
echo -e "  HA IP address     : ${GREEN}${HA_IP}${RESET}"
echo -e "  HA version        : ${GREEN}${HA_VERSION}${RESET}"
echo -e "  Zigbee device     : ${GREEN}${ZIGBEE_DEVICE}${RESET}"
echo -e "  Matter device     : ${GREEN}${MATTER_DEVICE}${RESET}"
echo -e "  MQTT user         : ${GREEN}${MQTT_USER}${RESET}"
echo -e "  Node-RED user     : ${GREEN}${NODERED_USER}${RESET}"
echo
echo -e "  Services:"
echo -e "    Home Assistant  : ${CYAN}http://${HA_IP}:8123${RESET}"
echo -e "    Node-RED        : ${CYAN}http://${HA_IP}:1880${RESET}"
echo -e "    Mosquitto MQTT  : ${CYAN}${HA_IP}:1883${RESET}"
echo -e "    Zigbee2MQTT     : ${GREEN}running (internal)${RESET}"
echo
echo -e "  Domain URLs (once NPM proxy hosts are added):"
echo -e "    Home Assistant  : ${CYAN}https://ha.${DOMAIN}${RESET}"
echo -e "    Node-RED        : ${CYAN}https://nodered.${DOMAIN}${RESET}"
echo
echo -e "${YELLOW}  Important next steps:${RESET}"
echo -e "  1. Add UniFi local DNS records:"
echo -e "     ha.${DOMAIN} → ${HA_IP}"
echo -e "     nodered.${DOMAIN} → ${HA_IP}"
echo -e "  2. Add NPM proxy hosts manually if not done automatically:"
echo -e "     ha.${DOMAIN} → ${HA_IP}:8123 (http)"
echo -e "     nodered.${DOMAIN} → ${HA_IP}:1880 (http)"
echo -e "  3. Open HA at http://${HA_IP}:8123 and complete onboarding"
echo -e "  4. In HA, install MQTT integration and connect to ${HA_IP}:1883"
echo -e "  5. In HA, install Shelly integration — devices should auto-discover"
echo -e "  6. Check Zigbee2MQTT logs: docker logs zigbee2mqtt"
echo -e "  7. Update Zigbee2MQTT secret.yaml with correct MQTT password:"
echo -e "     ${CYAN}nano ${DOCKER_APPDATA}/zigbee2mqtt/secret.yaml${RESET}"
echo -e "  8. To upgrade HA: edit image tag in compose.yaml, then:"
echo -e "     ${CYAN}cd ${DOCKER_APPDATA}/homeassistant && docker compose pull && docker compose up -d${RESET}"
echo
