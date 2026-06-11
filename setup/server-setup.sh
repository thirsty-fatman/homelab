#!/usr/bin/env bash
# =============================================================================
# Ubuntu Server 24.04 - Post-Install Setup Script
# =============================================================================
# Version  : 1.8.2
# Created  : 2026-06-09
# Author   : github.com/thirsty-fatman
#
# Changelog:
#   1.8.2 - 2026-06-11 - Detect existing authorized_keys before prompting for
#                         SSH public key. If keys are already present (e.g.
#                         populated via GitHub .keys download before running
#                         this script), show them and skip the manual paste
#                         prompt unless the user opts to add a different key.
#   1.8.1 - 2026-06-10 - Updated generated services.yaml order to match
#                         preferred layout. Portainer always included
#                         (active or commented based on install choice).
#   1.8.0 - 2026-06-10 - Added post-setup optional configuration menu.
#                         Options to run cloudflare-setup.sh and npm-setup.sh
#                         inline or later. NPM option validates Cloudflare
#                         setup completed first.
#   1.7.0 - 2026-06-10 - Fixed compose volume paths to use \${APPDATA} variable.
#                         Added GitHub username prompt — removes thirsty-fatman
#                         from script body. Used in bookmarks and clone URL.
#   1.6.0 - 2026-06-10 - Router IP auto-derived from server LAN IP as default (.1).
#                         Added Docker connection name prompt (after Server LAN IP),
#                         validated to lowercase letters, numbers, hyphens only.
#                         Default Docker connection name: server-docker.
#   1.5.0 - 2026-06-10 - Added router IP prompt (no default, never hardcoded).
#                         Added optional Portainer install (y/N prompt).
#                         Added NPM stack deployment.
#                         Replaced my-docker with osan-docker in Homepage config.
#                         Fixed IP references to use SERVER_LAN_IP variable.
#                         Router IP used in Homepage bookmarks only at runtime.
#                         Timezone defaults to Australia/Brisbane on fresh UTC install.
#   1.4.0 - 2026-06-09 - Removed Portainer. Added Homepage dashboard with
#                         starter config files. Default timezone changed to
#                         Australia/Brisbane. Fixed curl|bash stdin issue.
#   1.3.0 - 2026-06-09 - Added .env file generation for Docker stack.
#                         Added Socket Proxy, Portainer CE, Dockge stacks.
#                         Added Server LAN IP and timezone detection.
#   1.2.0 - 2026-06-09 - Added SSH key authentication and GitHub SSH key generation.
#   1.1.0 - 2026-06-09 - Removed all hardcoded personal info. Renamed to server-setup.sh.
#   1.0.0 - 2026-06-09 - Initial release
#
# Description:
#   Interactive post-install script for Ubuntu Server 24.04.
#   Prompts for all settings with no hardcoded personal information.
#   Safe to publish publicly — contains no usernames, hostnames,
#   passwords, IP addresses, or identifying information.
#
# What this script does:
#   1.  Sets hostname and timezone
#   2.  Validates or creates the primary user
#   3.  Sets up SSH key authentication (passwordless login)
#   4.  Generates a GitHub SSH key pair for git authentication
#   5.  Runs apt update + upgrade
#   6.  Installs prerequisite packages
#   7.  Installs Docker CE (official apt method)
#   8.  Adds user to docker group
#   9.  Generates /opt/docker/.env file
#   10. Creates Docker directory structure
#   11. Applies POSIX ACLs on Docker directories
#   12. Configures Docker log limits
#   13. Deploys Socket Proxy (compose stack)
#   14. Deploys Dockge (compose stack)
#   15. Deploys Homepage dashboard (compose stack + starter config)
#   16. Deploys NGINX Proxy Manager (compose stack)
#   17. Optionally deploys Portainer CE (compose stack)
#
# Usage:
#   Download and run — do NOT pipe curl directly into bash as it breaks
#   interactive prompts:
#
#   curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/server-setup.sh -o server-setup.sh
#   chmod +x server-setup.sh
#   sudo bash server-setup.sh
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
  error "This script must be run as root. Try: sudo bash server-setup.sh"
  exit 1
fi

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
# Helper: prompt required (no default, asked twice to catch typos)
# -----------------------------------------------------------------------------
prompt_required() {
  local varname="$1"
  local question="$2"
  local input1 input2

  while true; do
    echo -e "${BOLD}${question}${RESET}"
    read -rp "  Enter value: " input1 < /dev/tty
    echo

    if [[ -z "$input1" ]]; then
      warn "Value cannot be blank. Please try again."
      continue
    fi

    read -rp "  Confirm value (type again): " input2 < /dev/tty
    echo

    if [[ "$input1" == "$input2" ]]; then
      printf -v "$varname" '%s' "$input1"
      break
    else
      warn "Values do not match. Please try again."
    fi
  done
}

# -----------------------------------------------------------------------------
# Helper: prompt required single entry (no default, no confirmation)
# -----------------------------------------------------------------------------
prompt_required_single() {
  local varname="$1"
  local question="$2"
  local input

  while true; do
    echo -e "${BOLD}${question}${RESET}"
    read -rp "  Enter value: " input < /dev/tty
    echo

    if [[ -z "$input" ]]; then
      warn "Value cannot be blank. Please try again."
      continue
    fi

    printf -v "$varname" '%s' "$input"
    break
  done
}

# -----------------------------------------------------------------------------
# Helper: prompt password (hidden, confirmed, minimum 8 characters)
# -----------------------------------------------------------------------------
prompt_password() {
  local varname="$1"
  local username="$2"
  local pass1 pass2

  while true; do
    echo -e "${BOLD}Password for new user '${username}'${RESET}"
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
# Helper: prompt for SSH public key
# -----------------------------------------------------------------------------
prompt_ssh_pubkey() {
  local varname="$1"
  local input

  while true; do
    echo -e "${BOLD}SSH public key for passwordless login${RESET}"
    echo -e "  Paste your public key (starts with ssh-ed25519 or ssh-rsa)."
    echo -e "  Press Enter to skip if you do not have one yet."
    read -rp "  Public key: " input < /dev/tty
    echo

    if [[ -z "$input" ]]; then
      printf -v "$varname" '%s' ""
      break
    elif [[ "$input" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256)\ [A-Za-z0-9+/=]+ ]]; then
      printf -v "$varname" '%s' "$input"
      break
    else
      warn "That doesn't look like a valid public key. Please try again, or press Enter to skip."
    fi
  done
}

# =============================================================================
# STEP 1 — Interactive menu
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "   Ubuntu Server 24.04 - Post-Install Setup"
echo "   v1.8.2 | 2026-06-11"
echo "============================================================"
echo -e "${RESET}"
echo -e "For each question, press ${YELLOW}Enter${RESET} to accept the default,"
echo -e "or type a new value and press Enter.\n"

# --- Hostname ----------------------------------------------------------------
header "System Settings"
CURRENT_HOSTNAME=$(hostname)
prompt_default NEW_HOSTNAME "Hostname" "$CURRENT_HOSTNAME"

# --- Username ----------------------------------------------------------------
header "Primary User"
prompt_required USERNAME "Username (type carefully — asked twice to confirm)"

USER_EXISTS=false
if id "$USERNAME" &>/dev/null; then
  USER_EXISTS=true
  info "User '${USERNAME}' already exists on this system."
  info "Skipping user creation and password — will assign docker group and ACLs only."
  echo
else
  warn "User '${USERNAME}' does not exist and will be created."
  prompt_password PASSWORD "$USERNAME"
fi

# --- SSH public key ----------------------------------------------------------
header "SSH Key Authentication (Passwordless Login)"

# Check if authorized_keys already has content (e.g. populated via GitHub
# download one-liner before running this script)
EXISTING_AUTH_KEYS=""
SSH_PUBKEY=""
SKIP_PUBKEY_PROMPT=false

# Determine the home directory to check — depends on whether user exists yet
if [[ "$USER_EXISTS" == true ]]; then
  CHECK_HOME=$(eval echo "~${USERNAME}")
else
  CHECK_HOME="$HOME"
fi

CHECK_AUTH_FILE="${CHECK_HOME}/.ssh/authorized_keys"

if [[ -s "$CHECK_AUTH_FILE" ]] 2>/dev/null; then
  EXISTING_AUTH_KEYS=$(grep -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256)' "$CHECK_AUTH_FILE" 2>/dev/null || echo "")

  if [[ -n "$EXISTING_AUTH_KEYS" ]]; then
    KEY_COUNT=$(echo "$EXISTING_AUTH_KEYS" | wc -l)
    info "Found ${KEY_COUNT} existing key(s) in ${CHECK_AUTH_FILE}:"
    echo
    while IFS= read -r line; do
      # Show key type and a truncated fingerprint-ish preview for readability
      KEY_TYPE=$(echo "$line" | awk '{print $1}')
      KEY_COMMENT=$(echo "$line" | awk '{print $3}')
      KEY_PREVIEW=$(echo "$line" | awk '{print $2}' | cut -c1-20)
      echo -e "    ${CYAN}${KEY_TYPE}${RESET} ${KEY_PREVIEW}... ${KEY_COMMENT}"
    done <<< "$EXISTING_AUTH_KEYS"
    echo
    read -rp "$(echo -e "${BOLD}Use existing key(s) as-is? [Y/n]: ${RESET}")" USE_EXISTING < /dev/tty
    echo

    if [[ ! "$USE_EXISTING" =~ ^[Nn]$ ]]; then
      success "Using existing authorized_keys — skipping public key prompt."
      SKIP_PUBKEY_PROMPT=true
      # Use the first key found for SSH_PUBKEY (used later for summary/checks)
      SSH_PUBKEY=$(echo "$EXISTING_AUTH_KEYS" | head -1)
    fi
  fi
fi

if [[ "$SKIP_PUBKEY_PROMPT" == false ]]; then
  echo -e "  To get your public key on Windows, run in PowerShell:"
  echo -e "  ${CYAN}cat ~/.ssh/id_ed25519.pub${RESET}\n"
  prompt_ssh_pubkey SSH_PUBKEY
fi

# --- GitHub SSH key ----------------------------------------------------------
header "GitHub SSH Key"
echo -e "  A new SSH key pair will be generated on this server for GitHub authentication."
echo -e "  At the end of setup the public key will be displayed for you to add to GitHub.\n"
echo -e "${BOLD}Email address for GitHub SSH key label${RESET}"
read -rp "  Email: " GITHUB_EMAIL < /dev/tty
echo

echo -e "${BOLD}GitHub username${RESET}"
echo -e "  Used in bookmarks and git clone URL."
read -rp "  GitHub username: " GITHUB_USERNAME < /dev/tty
echo

# --- Network -----------------------------------------------------------------
header "Network"
DETECTED_IP=$(hostname -I | awk '{print $1}')
prompt_default SERVER_LAN_IP "Server LAN IP address" "$DETECTED_IP"

# Derive default router IP by replacing last octet with .1
DERIVED_ROUTER_IP=$(echo "$SERVER_LAN_IP" | sed 's/\.[0-9]*$/.1/')
prompt_default ROUTER_IP "Router/gateway IP address" "$DERIVED_ROUTER_IP"

# --- Docker connection name --------------------------------------------------
# Used as the label in Homepage docker.yaml and services.yaml server: entries.
# Allowed characters: lowercase letters, numbers, hyphens only.
while true; do
  echo -e "${BOLD}Docker connection name${RESET}"
  echo -e "  Used in Homepage to identify this Docker host."
  echo -e "  Current/default: ${YELLOW}server-docker${RESET}"
  echo -e "  Allowed characters: lowercase letters, numbers, hyphens (e.g. server-docker)"
  read -rp "  New value (Enter to keep): " DOCKER_NAME_INPUT < /dev/tty
  echo
  if [[ -z "$DOCKER_NAME_INPUT" ]]; then
    DOCKER_CONNECTION_NAME="server-docker"
    break
  elif [[ "$DOCKER_NAME_INPUT" =~ ^[a-z0-9-]+$ ]]; then
    DOCKER_CONNECTION_NAME="$DOCKER_NAME_INPUT"
    break
  else
    warn "Invalid characters. Use lowercase letters, numbers, and hyphens only."
  fi
done

# --- Timezone ----------------------------------------------------------------
header "Timezone"
DETECTED_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")

echo -e "${BOLD}Timezone${RESET}"
echo -e "  Current/default: ${YELLOW}${DETECTED_TZ}${RESET}"
if [[ "$DETECTED_TZ" == "UTC" ]]; then
  echo -e "  ${YELLOW}Note:${RESET} UTC is the fresh install default — you may want to change this."
fi
echo -e "  Valid timezone names: ${CYAN}https://en.wikipedia.org/wiki/List_of_tz_database_time_zones${RESET}"
echo -e "  (see the TZ Identifier column)"

while true; do
  read -rp "  New value (Enter to keep): " TZ_INPUT < /dev/tty
  echo

  if [[ -z "$TZ_INPUT" ]]; then
    TIMEZONE="$DETECTED_TZ"
    break
  fi

  # Validate against system timezone list
  if timedatectl list-timezones | grep -qx "$TZ_INPUT"; then
    TIMEZONE="$TZ_INPUT"
    break
  else
    warn "'${TZ_INPUT}' is not a valid timezone identifier. Please check the link above and try again."
  fi
done

# --- Docker directories ------------------------------------------------------
header "Docker Directory Structure"
prompt_default DOCKER_BASE    "Docker base directory"  "/opt/docker"
prompt_default DOCKER_APPDATA "Appdata subdirectory"   "${DOCKER_BASE}/appdata"
prompt_default DOCKER_VOLUMES "Volumes subdirectory"   "${DOCKER_BASE}/volumes"

# --- Optional Portainer ------------------------------------------------------
header "Optional Components"
echo -e "${BOLD}Install Portainer CE? (Docker management UI, port 9443)${RESET}"
read -rp "  Install Portainer? [y/N]: " INSTALL_PORTAINER < /dev/tty
echo
INSTALL_PORTAINER=${INSTALL_PORTAINER,,}  # lowercase

# =============================================================================
# STEP 2 — Confirmation summary
# =============================================================================
header "Confirmation Summary"
echo -e "  Hostname          : ${YELLOW}${NEW_HOSTNAME}${RESET}"
echo -e "  Username          : ${YELLOW}${USERNAME}${RESET}"

if [[ "$USER_EXISTS" == true ]]; then
  echo -e "  User action       : ${YELLOW}Existing user — no password change${RESET}"
else
  echo -e "  User action       : ${YELLOW}New user will be created${RESET}"
  echo -e "  Password          : ${YELLOW}(set — not displayed)${RESET}"
fi

if [[ -n "$SSH_PUBKEY" ]]; then
  echo -e "  SSH key login     : ${YELLOW}Yes — key will be installed${RESET}"
else
  echo -e "  SSH key login     : ${YELLOW}Skipped — password login only${RESET}"
fi

echo -e "  GitHub SSH key    : ${YELLOW}Will be generated (${GITHUB_EMAIL})${RESET}"
echo -e "  GitHub username   : ${YELLOW}${GITHUB_USERNAME}${RESET}"
echo -e "  Server LAN IP     : ${YELLOW}${SERVER_LAN_IP}${RESET}"
echo -e "  Router IP         : ${YELLOW}${ROUTER_IP}${RESET}"
echo -e "  Docker conn. name : ${YELLOW}${DOCKER_CONNECTION_NAME}${RESET}"
echo -e "  Timezone          : ${YELLOW}${TIMEZONE}${RESET}"
echo -e "  Docker base       : ${YELLOW}${DOCKER_BASE}${RESET}"
echo -e "  Appdata directory : ${YELLOW}${DOCKER_APPDATA}${RESET}"
echo -e "  Volumes directory : ${YELLOW}${DOCKER_VOLUMES}${RESET}"
echo
echo -e "  Stacks to be deployed:"
echo -e "    - Socket Proxy          (internal only)"
echo -e "    - Dockge                (port ${YELLOW}5001${RESET})"
echo -e "    - Homepage              (port ${YELLOW}3000${RESET})"
echo -e "    - NGINX Proxy Manager   (ports ${YELLOW}80, 443, 81${RESET})"

if [[ "$INSTALL_PORTAINER" == "y" ]]; then
  echo -e "    - Portainer CE          (port ${YELLOW}9443${RESET})"
fi

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
# STEP 3 — Set hostname and timezone
# -----------------------------------------------------------------------------
header "Setting Hostname and Timezone"
hostnamectl set-hostname "$NEW_HOSTNAME"

if grep -q "127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
else
  echo -e "127.0.1.1\t${NEW_HOSTNAME}" >> /etc/hosts
fi
success "Hostname set to: ${NEW_HOSTNAME}"

timedatectl set-timezone "$TIMEZONE"
success "Timezone set to: ${TIMEZONE}"

# -----------------------------------------------------------------------------
# STEP 4 — Create user if needed
# -----------------------------------------------------------------------------
header "User Account"
if [[ "$USER_EXISTS" == false ]]; then
  info "Creating user '${USERNAME}'..."
  useradd -m -s /bin/bash "$USERNAME"
  echo "${USERNAME}:${PASSWORD}" | chpasswd
  PASSWORD=""
  success "User '${USERNAME}' created with password set."
else
  info "User '${USERNAME}' already exists — skipping creation."
fi

if ! groups "$USERNAME" | grep -q "\bsudo\b"; then
  usermod -aG sudo "$USERNAME"
  success "User '${USERNAME}' added to sudo group."
else
  info "User '${USERNAME}' is already in sudo group."
fi

# -----------------------------------------------------------------------------
# STEP 5 — SSH key authentication
# -----------------------------------------------------------------------------
header "SSH Key Authentication"
USER_HOME=$(eval echo "~${USERNAME}")
SSH_DIR="${USER_HOME}/.ssh"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "${USERNAME}:${USERNAME}" "$SSH_DIR"

if [[ -n "$SSH_PUBKEY" ]]; then
  AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
  if grep -qF "$SSH_PUBKEY" "$AUTHORIZED_KEYS" 2>/dev/null; then
    info "SSH public key already present — skipping."
  else
    echo "$SSH_PUBKEY" >> "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    chown "${USERNAME}:${USERNAME}" "$AUTHORIZED_KEYS"
    success "SSH public key added to ${AUTHORIZED_KEYS}."
  fi
else
  info "No SSH public key provided — password login remains active."
fi

# -----------------------------------------------------------------------------
# STEP 6 — Generate GitHub SSH key pair
# -----------------------------------------------------------------------------
header "Generating GitHub SSH Key"
GITHUB_KEY_PATH="${SSH_DIR}/id_ed25519_github"

if [[ -f "$GITHUB_KEY_PATH" ]]; then
  info "GitHub SSH key already exists — skipping generation."
else
  sudo -u "$USERNAME" ssh-keygen -t ed25519 \
    -C "$GITHUB_EMAIL" \
    -f "$GITHUB_KEY_PATH" \
    -N ""
  success "GitHub SSH key pair generated."
fi

SSH_CONFIG="${SSH_DIR}/config"
if ! grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" << EOF

# GitHub SSH authentication
Host github.com
  HostName github.com
  User git
  IdentityFile ${GITHUB_KEY_PATH}
  IdentitiesOnly yes
EOF
  chmod 600 "$SSH_CONFIG"
  chown "${USERNAME}:${USERNAME}" "$SSH_CONFIG"
  success "SSH config updated for GitHub."
else
  info "GitHub entry already exists in SSH config — skipping."
fi

GITHUB_PUBKEY=$(cat "${GITHUB_KEY_PATH}.pub")

# -----------------------------------------------------------------------------
# STEP 7 — apt update + upgrade
# -----------------------------------------------------------------------------
header "System Update"
info "Running apt update..."
apt-get update -y
info "Running apt upgrade..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
success "System updated."

# -----------------------------------------------------------------------------
# STEP 8 — Install prerequisites
# -----------------------------------------------------------------------------
header "Installing Prerequisites"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl \
  ca-certificates \
  gnupg \
  lsb-release \
  apt-transport-https \
  software-properties-common \
  acl \
  git \
  htop \
  nano \
  unzip \
  python3 \
  python3-pip
success "Prerequisites installed."

# -----------------------------------------------------------------------------
# STEP 9 — Install Docker CE
# -----------------------------------------------------------------------------
header "Installing Docker CE"

info "Adding Docker GPG key..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
success "Docker GPG key added."

info "Adding Docker apt repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
success "Docker repository added."

info "Installing Docker packages..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
success "Docker CE installed."

systemctl enable docker
systemctl start docker
success "Docker service enabled and started."

usermod -aG docker "$USERNAME"
success "User '${USERNAME}' added to docker group."

# -----------------------------------------------------------------------------
# STEP 10 — Configure Docker log limits
# -----------------------------------------------------------------------------
header "Configuring Docker Log Limits"
cat > /etc/docker/daemon.json << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker
success "Docker log limits configured (10MB max size, 3 files)."

# -----------------------------------------------------------------------------
# STEP 11 — Create Docker directory structure
# -----------------------------------------------------------------------------
header "Creating Docker Directory Structure"

USER_UID=$(id -u "$USERNAME")
USER_GID=$(id -g "$USERNAME")

mkdir -p "${DOCKER_BASE}"
mkdir -p "${DOCKER_APPDATA}"
mkdir -p "${DOCKER_VOLUMES}"
mkdir -p "${DOCKER_APPDATA}/socket-proxy"
mkdir -p "${DOCKER_APPDATA}/dockge"
mkdir -p "${DOCKER_APPDATA}/dockge/stacks"
mkdir -p "${DOCKER_APPDATA}/homepage"
mkdir -p "${DOCKER_APPDATA}/homepage/config"
mkdir -p "${DOCKER_APPDATA}/npm"

if [[ "$INSTALL_PORTAINER" == "y" ]]; then
  mkdir -p "${DOCKER_APPDATA}/portainer"
fi

success "Directories created."

# -----------------------------------------------------------------------------
# STEP 12 — Generate .env file
# -----------------------------------------------------------------------------
header "Generating Docker .env File"

cat > "${DOCKER_BASE}/.env" << EOF
# =============================================================================
# Docker Stack Environment Variables
# =============================================================================
# Generated : $(date '+%Y-%m-%d %H:%M:%S')
# Host      : ${NEW_HOSTNAME}
#
# This file is sourced automatically by docker compose.
# DO NOT commit this file to version control.
# =============================================================================

# -----------------------------------------------------------------------------
# System
# -----------------------------------------------------------------------------
PUID=${USER_UID}
PGID=${USER_GID}
TZ=${TIMEZONE}
HOSTNAME=${NEW_HOSTNAME}
USERDIR=${USER_HOME}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
SERVER_LAN_IP=${SERVER_LAN_IP}
ROUTER_IP=${ROUTER_IP}
LOCAL_IPS=127.0.0.1/32,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12

# -----------------------------------------------------------------------------
# Docker directories
# -----------------------------------------------------------------------------
DOCKERDIR=${DOCKER_BASE}
APPDATA=${DOCKER_APPDATA}
VOLUMES=${DOCKER_VOLUMES}

# -----------------------------------------------------------------------------
# Socket Proxy
# -----------------------------------------------------------------------------
DOCKER_HOST=tcp://socket-proxy:2375

# -----------------------------------------------------------------------------
# Homepage Docker connection name
# -----------------------------------------------------------------------------
DOCKER_CONNECTION_NAME=${DOCKER_CONNECTION_NAME}

# -----------------------------------------------------------------------------
# GitHub
# -----------------------------------------------------------------------------
GITHUB_USERNAME=${GITHUB_USERNAME}

# -----------------------------------------------------------------------------
# Container ports
# -----------------------------------------------------------------------------
DOCKGE_PORT=5001
HOMEPAGE_PORT=3000
NPM_HTTP_PORT=80
NPM_HTTPS_PORT=443
NPM_ADMIN_PORT=81
PORTAINER_PORT=9443
EOF

chmod 600 "${DOCKER_BASE}/.env"
chown "${USERNAME}:${USERNAME}" "${DOCKER_BASE}/.env"
success ".env file generated at ${DOCKER_BASE}/.env"

# -----------------------------------------------------------------------------
# STEP 13 — POSIX ACLs
# -----------------------------------------------------------------------------
header "Applying POSIX ACLs"
chown -R "${USERNAME}:${USERNAME}" "${DOCKER_BASE}"
setfacl -R -m u:"${USERNAME}":rwx "${DOCKER_BASE}"
setfacl -R -d -m u:"${USERNAME}":rwx "${DOCKER_BASE}"
success "POSIX ACLs applied to ${DOCKER_BASE}."

# -----------------------------------------------------------------------------
# STEP 14 — Deploy Socket Proxy
# -----------------------------------------------------------------------------
header "Deploying Socket Proxy"

cat > "${DOCKER_APPDATA}/socket-proxy/compose.yaml" << EOF
# =============================================================================
# Socket Proxy
# =============================================================================
# Protects the Docker socket by acting as a firewall between containers
# and the Docker API. Only the API endpoints listed below are accessible.
# =============================================================================

networks:
  socket_proxy:
    name: socket_proxy
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.91.0/24  # Internal Docker-only subnet for container-to-container
                                       # communication. Not visible on your LAN.
                                       # This IP range is not assigned by the author —
                                       # it is a private range chosen to avoid conflicts.

services:
  socket-proxy:
    image: lscr.io/linuxserver/socket-proxy:latest
    container_name: socket-proxy
    restart: unless-stopped
    networks:
      socket_proxy:
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - INFO=1
      - NETWORKS=1
      - SERVICES=1
      - TASKS=1
      - VOLUMES=1
      - EVENTS=1
      - PING=1
      - POST=1
EOF

chown -R "${USERNAME}:${USERNAME}" "${DOCKER_APPDATA}/socket-proxy"
docker compose -f "${DOCKER_APPDATA}/socket-proxy/compose.yaml" up -d
success "Socket Proxy deployed."

# -----------------------------------------------------------------------------
# STEP 15 — Deploy Dockge
# -----------------------------------------------------------------------------
header "Deploying Dockge"

cat > "${DOCKER_APPDATA}/dockge/compose.yaml" << EOF
# =============================================================================
# Dockge
# =============================================================================
# Compose file management UI.
# UI: http://${SERVER_LAN_IP}:5001
# Stacks folder: ${DOCKER_APPDATA}/dockge/stacks
# =============================================================================

networks:
  socket_proxy:
    name: socket_proxy
    external: true

services:
  dockge:
    image: louislam/dockge:latest
    container_name: dockge
    restart: unless-stopped
    networks:
      - socket_proxy
    ports:
      - "\${DOCKGE_PORT:-5001}:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - \${APPDATA}/dockge:/app/data
      - \${APPDATA}/dockge/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
EOF

chown -R "${USERNAME}:${USERNAME}" "${DOCKER_APPDATA}/dockge"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/dockge/compose.yaml" \
  up -d
success "Dockge deployed."

# -----------------------------------------------------------------------------
# STEP 16 — Deploy Homepage
# -----------------------------------------------------------------------------
header "Deploying Homepage Dashboard"

cat > "${DOCKER_APPDATA}/homepage/compose.yaml" << EOF
# =============================================================================
# Homepage Dashboard
# =============================================================================
# Homelab dashboard with Docker container auto-discovery via Socket Proxy.
# UI: http://${SERVER_LAN_IP}:3000
#
# Config files: ${DOCKER_APPDATA}/homepage/config/
# To update services: edit config/services.yaml then:
#   docker compose -f ${DOCKER_APPDATA}/homepage/compose.yaml restart
# =============================================================================

networks:
  socket_proxy:
    name: socket_proxy
    external: true

services:
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    networks:
      - socket_proxy
    ports:
      - "\${HOMEPAGE_PORT:-3000}:3000"
    volumes:
      - \${APPDATA}/homepage/config:/app/config
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
      - HOMEPAGE_ALLOWED_HOSTS=*
EOF

cat > "${DOCKER_APPDATA}/homepage/config/settings.yaml" << EOF
# =============================================================================
# Homepage - settings.yaml
# =============================================================================
title: ${NEW_HOSTNAME^^} - Home Lab Core
description: Homelab dashboard
layout:
  columns: 3
theme: dark
color: slate
hideSearch: false
showStats: true
hideUnlistedContainers: true
fontSize: xl
EOF

cat > "${DOCKER_APPDATA}/homepage/config/docker.yaml" << EOF
# =============================================================================
# Homepage - docker.yaml
# =============================================================================
# Connects Homepage to Docker via Socket Proxy for container auto-discovery.
# ${DOCKER_CONNECTION_NAME} is the label used in services.yaml server: entries.
# =============================================================================
${DOCKER_CONNECTION_NAME}:
  host: socket-proxy
  port: 2375
EOF

cat > "${DOCKER_APPDATA}/homepage/config/widgets.yaml" << EOF
# =============================================================================
# Homepage - widgets.yaml
# =============================================================================
- resources:
    label: ${NEW_HOSTNAME^^}
    cpu: true
    memory: true
    disk: /
    expanded: true

- datetime:
    text_size: xl
    format:
      dateStyle: long
      timeStyle: short
      hour12: true

- search:
    provider: duckduckgo
    target: _blank
EOF

cat > "${DOCKER_APPDATA}/homepage/config/bookmarks.yaml" << EOF
# =============================================================================
# Homepage - bookmarks.yaml
# =============================================================================
- Homelab:
  - GitHub Homelab Repo:
    - abbr: GH
      href: https://github.com/${GITHUB_USERNAME}/homelab
  - Router:
    - abbr: RT
      href: http://${ROUTER_IP}

- Documentation:
  - Docker Docs:
    - abbr: DD
      href: https://docs.docker.com
  - Homepage Docs:
    - abbr: HP
      href: https://gethomepage.dev/latest/
  - Ubuntu Server Docs:
    - abbr: UB
      href: https://ubuntu.com/server/docs
EOF

cat > "${DOCKER_APPDATA}/homepage/config/services.yaml" << EOF
# =============================================================================
# Homepage - services.yaml
# =============================================================================
# To add a new service copy a block and update the fields.
# Restart after changes:
#   docker compose -f ${DOCKER_APPDATA}/homepage/compose.yaml restart
#
# Note: URLs are initially set to IP:port format.
# After running npm-setup.sh, URLs are automatically updated to
# https://service.domain format. Manual overrides are preserved.
#
# Auto-discovery labels for compose.yaml:
#   labels:
#     - homepage.group=Group Name
#     - homepage.name=Service Name
#     - homepage.icon=icon-name
#     - homepage.href=http://x.x.x.x:port
#     - homepage.description=Short description
#     - homepage.server=${DOCKER_CONNECTION_NAME}
#     - homepage.container=container_name
# =============================================================================

- Core Infrastructure:
  - Homepage:
      href: http://${SERVER_LAN_IP}:3000
      description: This dashboard
      server: ${DOCKER_CONNECTION_NAME}
      container: homepage
      icon: homepage.png

  - NGINX Proxy Manager:
      href: http://${SERVER_LAN_IP}:81
      description: Reverse proxy manager
      server: ${DOCKER_CONNECTION_NAME}
      container: nginx-proxy-manager
      icon: nginx-proxy-manager.png

  - Portainer:
      href: https://${SERVER_LAN_IP}:9443
      description: Docker management UI
      server: ${DOCKER_CONNECTION_NAME}
      container: portainer
      icon: portainer.png

  - Dockge:
      href: http://${SERVER_LAN_IP}:5001
      description: Compose stack management
      server: ${DOCKER_CONNECTION_NAME}
      container: dockge
      icon: dockge.png

  - Socket Proxy:
      description: Docker socket proxy (internal)
      icon: docker.png

# - Home Automation:
#   - Home Assistant:
#       href: http://x.x.x.x:8123
#       description: Home automation platform
#       server: ${DOCKER_CONNECTION_NAME}
#       container: homeassistant
#       icon: home-assistant.png
#
#   - Node-RED:
#       href: http://x.x.x.x:1880
#       description: Automation flow editor
#       server: ${DOCKER_CONNECTION_NAME}
#       container: nodered
#       icon: node-red.png
#
#   - Mosquitto:
#       description: MQTT broker (internal)
#       server: ${DOCKER_CONNECTION_NAME}
#       container: mosquitto
#       icon: mosquitto.png

# - Network:
#   - Uptime Kuma:
#       href: http://x.x.x.x:3001
#       description: Service uptime monitoring
#       server: ${DOCKER_CONNECTION_NAME}
#       container: uptime-kuma
#       icon: uptime-kuma.png
EOF

chown -R "${USERNAME}:${USERNAME}" "${DOCKER_APPDATA}/homepage"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/homepage/compose.yaml" \
  up -d
success "Homepage dashboard deployed."

# -----------------------------------------------------------------------------
# STEP 17 — Deploy NGINX Proxy Manager
# -----------------------------------------------------------------------------
header "Deploying NGINX Proxy Manager"

cat > "${DOCKER_APPDATA}/npm/compose.yaml" << EOF
# =============================================================================
# NGINX Proxy Manager
# =============================================================================
# Reverse proxy with SSL certificate management via Let's Encrypt.
# Connects to Docker via Socket Proxy network.
#
# Admin UI : http://${SERVER_LAN_IP}:81
# HTTP     : port 80
# HTTPS    : port 443
#
# Default credentials (change immediately on first login):
#   Email    : admin@example.com
#   Password : changeme
#
# SSL certificates: use DNS challenge with Cloudflare API token
# for wildcard certificates that work without external access.
# =============================================================================

networks:
  socket_proxy:
    name: socket_proxy
    external: true

services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    networks:
      - socket_proxy
    ports:
      - "\${NPM_HTTP_PORT:-80}:80"
      - "\${NPM_HTTPS_PORT:-443}:443"
      - "\${NPM_ADMIN_PORT:-81}:81"
    volumes:
      - \${APPDATA}/npm/data:/data
      - \${APPDATA}/npm/letsencrypt:/etc/letsencrypt
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
EOF

chown -R "${USERNAME}:${USERNAME}" "${DOCKER_APPDATA}/npm"
docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/npm/compose.yaml" \
  up -d
success "NGINX Proxy Manager deployed."

# -----------------------------------------------------------------------------
# STEP 18 — Deploy Portainer (optional)
# -----------------------------------------------------------------------------
if [[ "$INSTALL_PORTAINER" == "y" ]]; then
  header "Deploying Portainer CE"

  cat > "${DOCKER_APPDATA}/portainer/compose.yaml" << EOF
# =============================================================================
# Portainer CE
# =============================================================================
# Docker management UI — use for monitoring and visibility.
# Connects to Docker via Socket Proxy.
#
# UI: https://${SERVER_LAN_IP}:9443
# Note: Self-signed certificate — browser will show a security warning.
# =============================================================================

networks:
  socket_proxy:
    name: socket_proxy
    external: true

services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    networks:
      - socket_proxy
    ports:
      - "\${PORTAINER_PORT:-9443}:9443"
    volumes:
      - \${APPDATA}/portainer:/data
    environment:
      - DOCKER_HOST=tcp://socket-proxy:2375
    command: --http-disabled
EOF

  chown -R "${USERNAME}:${USERNAME}" "${DOCKER_APPDATA}/portainer"
  docker compose \
    --env-file "${DOCKER_BASE}/.env" \
    -f "${DOCKER_APPDATA}/portainer/compose.yaml" \
    up -d
  success "Portainer CE deployed."
fi

# =============================================================================
# STEP 19 — Post-setup optional configuration
# =============================================================================

# -----------------------------------------------------------------------------
# Helper: download and run a setup script inline
# -----------------------------------------------------------------------------
run_setup_script() {
  local script_name="$1"
  local script_url="https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/${script_name}"
  local script_path="/tmp/${script_name}"

  info "Downloading ${script_name}..."
  if curl -fsSL "$script_url" -o "$script_path"; then
    chmod +x "$script_path"
    success "Downloaded ${script_name}."
    echo
    bash "$script_path"
  else
    error "Failed to download ${script_name} from GitHub."
    error "Run it manually later:"
    echo -e "  ${CYAN}curl -fsSL ${script_url} -o ${script_name}${RESET}"
    echo -e "  ${CYAN}sudo bash ${script_name}${RESET}"
  fi
}

# -----------------------------------------------------------------------------
# Helper: check if Cloudflare setup has been completed
# -----------------------------------------------------------------------------
check_cloudflare_setup() {
  local env_file="${DOCKER_BASE}/.env"
  local missing=()

  for var in CLOUDFLARE_TOKEN DOMAIN ZONE_ID; do
    if ! grep -q "^${var}=" "$env_file" 2>/dev/null; then
      missing+=("$var")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Post-setup menu
# -----------------------------------------------------------------------------
header "Optional Post-Setup Configuration"
echo -e "  Cloudflare DNS and NPM can be configured now or later."
echo -e "  NPM setup requires Cloudflare setup to have been completed first.
"

SKIP_SETUP=false

while true; do
  echo -e "  ${BOLD}1.${RESET} Run both Cloudflare and NPM setup"
  echo -e "  ${BOLD}2.${RESET} Run Cloudflare setup only"
  echo -e "  ${BOLD}3.${RESET} Run NPM setup only (requires Cloudflare setup first)"
  echo -e "  ${BOLD}4.${RESET} Skip — I will run these later"
  echo
  read -rp "  Enter choice [1-4]: " POST_CHOICE < /dev/tty
  echo

  case "$POST_CHOICE" in
    1)
      # Run Cloudflare then NPM
      run_setup_script "cloudflare-setup.sh"
      echo
      run_setup_script "npm-setup.sh"
      break
      ;;
    2)
      # Run Cloudflare only, then ask about NPM
      run_setup_script "cloudflare-setup.sh"
      echo
      header "NPM Setup"
      echo -e "  Cloudflare setup is complete."
      read -rp "  Run NPM setup now? [y/N]: " RUN_NPM < /dev/tty
      echo
      if [[ "$RUN_NPM" =~ ^[Yy]$ ]]; then
        run_setup_script "npm-setup.sh"
      else
        SKIP_SETUP=true
      fi
      break
      ;;
    3)
      # NPM only — validate Cloudflare setup first
      if check_cloudflare_setup; then
        run_setup_script "npm-setup.sh"
        break
      else
        warn "Cloudflare setup has not been completed."
        warn "CLOUDFLARE_TOKEN, DOMAIN, or ZONE_ID not found in ${DOCKER_BASE}/.env"
        echo
        echo -e "  ${BOLD}1.${RESET} Run Cloudflare setup first then NPM setup"
        echo -e "  ${BOLD}2.${RESET} Skip both — run manually later"
        echo
        read -rp "  Enter choice [1-2]: " CF_CHOICE < /dev/tty
        echo
        if [[ "$CF_CHOICE" == "1" ]]; then
          run_setup_script "cloudflare-setup.sh"
          echo
          run_setup_script "npm-setup.sh"
        else
          SKIP_SETUP=true
        fi
        break
      fi
      ;;
    4)
      SKIP_SETUP=true
      break
      ;;
    *)
      warn "Invalid choice. Please enter 1, 2, 3, or 4."
      ;;
  esac
done

# =============================================================================
# STEP 20 — Final summary
# =============================================================================
MACHINE_IP=$(hostname -I | awk '{print $1}')

echo
echo -e "${BOLD}${GREEN}"
echo "============================================================"
echo "   Setup Complete"
echo "============================================================"
echo -e "${RESET}"
echo -e "  Hostname          : ${GREEN}${NEW_HOSTNAME}${RESET}"
echo -e "  Username          : ${GREEN}${USERNAME}${RESET}"
echo -e "  Timezone          : ${GREEN}${TIMEZONE}${RESET}"
echo -e "  Server LAN IP     : ${GREEN}${SERVER_LAN_IP}${RESET}"
echo -e "  Docker base       : ${GREEN}${DOCKER_BASE}${RESET}"
echo -e "  Appdata directory : ${GREEN}${DOCKER_APPDATA}${RESET}"
echo -e "  Volumes directory : ${GREEN}${DOCKER_VOLUMES}${RESET}"
echo -e "  .env file         : ${GREEN}${DOCKER_BASE}/.env${RESET}"
echo
echo -e "  Stacks deployed:"
echo -e "    Socket Proxy          : ${GREEN}running (internal)${RESET}"
echo -e "    Dockge                : ${CYAN}http://${MACHINE_IP}:5001${RESET}"
echo -e "    Homepage              : ${CYAN}http://${MACHINE_IP}:3000${RESET}"
echo -e "    NGINX Proxy Manager   : ${CYAN}http://${MACHINE_IP}:81${RESET}"

if [[ "$INSTALL_PORTAINER" == "y" ]]; then
  echo -e "    Portainer CE          : ${CYAN}https://${MACHINE_IP}:9443${RESET}"
fi

echo

if [[ -n "$SSH_PUBKEY" ]]; then
  echo -e "${GREEN}  Passwordless SSH login is configured.${RESET}"
  echo -e "  Connect from Windows: ${CYAN}ssh ${USERNAME}@${MACHINE_IP}${RESET}"
else
  echo -e "${YELLOW}  No SSH public key provided — password login still required.${RESET}"
  echo -e "  To add a key later, paste your public key into:"
  echo -e "  ${CYAN}~/.ssh/authorized_keys${RESET}"
fi
echo

echo -e "${BOLD}${YELLOW}  ACTION REQUIRED — Add GitHub SSH key${RESET}"
echo -e "  Copy the key below and add it to GitHub:"
echo -e "  ${CYAN}https://github.com/settings/ssh/new${RESET}"
echo
echo -e "${BOLD}  Title suggestion:${RESET} ${NEW_HOSTNAME} server"
echo -e "${BOLD}  Key type:${RESET} Authentication Key"
echo -e "${BOLD}  Key:${RESET}"
echo
echo -e "  ${CYAN}${GITHUB_PUBKEY}${RESET}"
echo
echo -e "  Once added, test with:  ${CYAN}ssh -T git@github.com${RESET}"
echo -e "  Then clone your repo:   ${CYAN}git clone git@github.com:${GITHUB_USERNAME}/homelab.git${RESET}"
echo

if [[ "$SKIP_SETUP" == true ]]; then
  echo -e "${YELLOW}  Cloudflare and NPM setup — run later:${RESET}"
  echo -e "  ${BOLD}Cloudflare DNS setup:${RESET}"
  echo -e "    ${CYAN}curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/cloudflare-setup.sh -o cloudflare-setup.sh${RESET}"
  echo -e "    ${CYAN}sudo bash cloudflare-setup.sh${RESET}"
  echo
  echo -e "  ${BOLD}NPM setup (run after Cloudflare setup):${RESET}"
  echo -e "    ${CYAN}curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/npm-setup.sh -o npm-setup.sh${RESET}"
  echo -e "    ${CYAN}sudo bash npm-setup.sh${RESET}"
  echo
fi

echo -e "${YELLOW}  Other important notes:${RESET}"
echo -e "  - Log out and back in (or reboot) for docker group membership to take effect"
echo -e "  - NPM default login: admin@example.com / changeme — change immediately if not done"
echo -e "  - Dockge stacks folder: ${DOCKER_APPDATA}/dockge/stacks"
echo -e "  - Homepage config: ${DOCKER_APPDATA}/homepage/config/"
echo -e "  - Use ${DOCKER_BASE}/.env as single source of truth for all stack variables"
echo
