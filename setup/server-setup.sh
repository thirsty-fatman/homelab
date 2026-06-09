#!/usr/bin/env bash
# =============================================================================
# Ubuntu Server 24.04 - Post-Install Setup Script
# =============================================================================
# Version  : 1.3.0
# Created  : 2026-06-09
# Author   : github.com/thirsty-fatman
#
# Changelog:
#   1.3.0 - 2026-06-09 - Added .env file generation for Docker stack.
#                         Added Socket Proxy compose stack.
#                         Added Portainer CE and Dockge (both installed).
#                         Added Server LAN IP detection with confirmation.
#                         Added timezone detection with confirmation.
#   1.2.0 - 2026-06-09 - Added SSH key authentication setup (passwordless login
#                         from Windows). Added GitHub SSH key generation so the
#                         server can authenticate to GitHub for git pull.
#   1.1.0 - 2026-06-09 - Removed all hardcoded personal info. Username asked
#                         twice to catch typos. Password only prompted when
#                         creating a new user. Renamed to server-setup.sh.
#   1.0.0 - 2026-06-09 - Initial release
#
# Description:
#   Interactive post-install script for Ubuntu Server 24.04.
#   Prompts for all settings with no hardcoded personal information.
#   Safe to publish publicly — contains no usernames, hostnames,
#   passwords, or identifying information.
#
# What this script does:
#   1.  Sets hostname
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
#   14. Deploys Portainer CE (compose stack)
#   15. Deploys Dockge (compose stack)
#
# Usage:
#   chmod +x server-setup.sh
#   sudo ./server-setup.sh
#
# Or directly from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/server-setup.sh | sudo bash
# =============================================================================

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

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
  error "This script must be run as root. Try: sudo ./server-setup.sh"
  exit 1
fi

# -----------------------------------------------------------------------------
# Helper: prompt with default
#   Shows current/default value. Enter to keep, or type a new value.
#   Usage: prompt_default VARNAME "Question text" "default value"
# -----------------------------------------------------------------------------
prompt_default() {
  local varname="$1"
  local question="$2"
  local default="$3"
  local input

  echo -e "${BOLD}${question}${RESET}"
  echo -e "  Current/default: ${YELLOW}${default}${RESET}"
  read -rp "  New value (Enter to keep): " input
  echo

  if [[ -z "$input" ]]; then
    printf -v "$varname" '%s' "$default"
  else
    printf -v "$varname" '%s' "$input"
  fi
}

# -----------------------------------------------------------------------------
# Helper: prompt required (no default, must type something)
#   Asked twice — both entries must match to catch typos.
#   Usage: prompt_required VARNAME "Question text"
# -----------------------------------------------------------------------------
prompt_required() {
  local varname="$1"
  local question="$2"
  local input1 input2

  while true; do
    echo -e "${BOLD}${question}${RESET}"
    read -rp "  Enter value: " input1
    echo

    if [[ -z "$input1" ]]; then
      warn "Value cannot be blank. Please try again."
      continue
    fi

    read -rp "  Confirm value (type again): " input2
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
# Helper: prompt password (hidden input, confirmed, minimum 8 characters)
#   Usage: prompt_password VARNAME "username"
# -----------------------------------------------------------------------------
prompt_password() {
  local varname="$1"
  local username="$2"
  local pass1 pass2

  while true; do
    echo -e "${BOLD}Password for new user '${username}'${RESET}"
    read -rsp "  Enter password: " pass1
    echo

    if [[ ${#pass1} -lt 8 ]]; then
      warn "Password must be at least 8 characters. Please try again."
      continue
    fi

    read -rsp "  Confirm password: " pass2
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
#   Validates that input looks like a real public key before accepting.
#   Usage: prompt_ssh_pubkey VARNAME
# -----------------------------------------------------------------------------
prompt_ssh_pubkey() {
  local varname="$1"
  local input

  while true; do
    echo -e "${BOLD}SSH public key for passwordless login${RESET}"
    echo -e "  Paste your public key (starts with ssh-ed25519 or ssh-rsa)."
    echo -e "  Press Enter to skip if you do not have one yet."
    read -rp "  Public key: " input
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
echo "   v1.3.0 | 2026-06-09"
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

# Check if user exists
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
echo -e "  To get your public key on Windows, run in PowerShell:"
echo -e "  ${CYAN}cat ~/.ssh/id_ed25519.pub${RESET}\n"
prompt_ssh_pubkey SSH_PUBKEY

# --- GitHub SSH key ----------------------------------------------------------
header "GitHub SSH Key"
echo -e "  A new SSH key pair will be generated on this server for GitHub authentication."
echo -e "  At the end of setup the public key will be displayed for you to add to GitHub.\n"
echo -e "${BOLD}Email address for GitHub SSH key label${RESET}"
read -rp "  Email: " GITHUB_EMAIL
echo

# --- Server LAN IP -----------------------------------------------------------
header "Network"
DETECTED_IP=$(hostname -I | awk '{print $1}')
prompt_default SERVER_LAN_IP "Server LAN IP address" "$DETECTED_IP"

# --- Timezone ----------------------------------------------------------------
DETECTED_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Australia/Brisbane")
prompt_default TIMEZONE "Timezone" "$DETECTED_TZ"

# --- Docker directories ------------------------------------------------------
header "Docker Directory Structure"
prompt_default DOCKER_BASE    "Docker base directory"  "/opt/docker"
prompt_default DOCKER_APPDATA "Appdata subdirectory"   "${DOCKER_BASE}/appdata"
prompt_default DOCKER_VOLUMES "Volumes subdirectory"   "${DOCKER_BASE}/volumes"

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
echo -e "  Server LAN IP     : ${YELLOW}${SERVER_LAN_IP}${RESET}"
echo -e "  Timezone          : ${YELLOW}${TIMEZONE}${RESET}"
echo -e "  Docker base       : ${YELLOW}${DOCKER_BASE}${RESET}"
echo -e "  Appdata directory : ${YELLOW}${DOCKER_APPDATA}${RESET}"
echo -e "  Volumes directory : ${YELLOW}${DOCKER_VOLUMES}${RESET}"
echo
echo -e "  Stacks to be deployed:"
echo -e "    - Socket Proxy  (internal only — no UI)"
echo -e "    - Portainer CE  (port ${YELLOW}9443${RESET})"
echo -e "    - Dockge        (port ${YELLOW}5001${RESET})"
echo
read -rp "$(echo -e "${BOLD}Proceed with these settings? [y/N]: ${RESET}")" CONFIRM
echo

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  warn "Aborted by user. Nothing has been changed."
  exit 0
fi

# =============================================================================
# From here everything runs unattended
# =============================================================================

# -----------------------------------------------------------------------------
# STEP 3 — Set hostname
# -----------------------------------------------------------------------------
header "Setting Hostname"
hostnamectl set-hostname "$NEW_HOSTNAME"

if grep -q "127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
else
  echo -e "127.0.1.1\t${NEW_HOSTNAME}" >> /etc/hosts
fi
success "Hostname set to: ${NEW_HOSTNAME}"

# --- Set timezone ------------------------------------------------------------
timedatectl set-timezone "$TIMEZONE"
success "Timezone set to: ${TIMEZONE}"

# -----------------------------------------------------------------------------
# STEP 4 — Create user if needed
# -----------------------------------------------------------------------------
header "User Account"
if [[ "$USER_EXISTS" == false ]]; then
  info "Creating user '${USERNAME}'..."
  useradd -m -s /bin/bash "$USERNAME"

  # Set password via stdin — never exposed in process list or logs
  echo "${USERNAME}:${PASSWORD}" | chpasswd

  # Clear password variable immediately after use
  PASSWORD=""

  success "User '${USERNAME}' created with password set."
else
  info "User '${USERNAME}' already exists — skipping creation."
fi

# Add to sudo group if not already a member
if ! groups "$USERNAME" | grep -q "\bsudo\b"; then
  usermod -aG sudo "$USERNAME"
  success "User '${USERNAME}' added to sudo group."
else
  info "User '${USERNAME}' is already in sudo group."
fi

# -----------------------------------------------------------------------------
# STEP 5 — SSH key authentication (passwordless login)
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
    info "SSH public key already present in authorized_keys — skipping."
  else
    echo "$SSH_PUBKEY" >> "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    chown "${USERNAME}:${USERNAME}" "$AUTHORIZED_KEYS"
    success "SSH public key added to ${AUTHORIZED_KEYS}."
  fi
else
  info "No SSH public key provided — skipping. Password login remains active."
fi

# -----------------------------------------------------------------------------
# STEP 6 — Generate GitHub SSH key pair
# -----------------------------------------------------------------------------
header "Generating GitHub SSH Key"
GITHUB_KEY_PATH="${SSH_DIR}/id_ed25519_github"

if [[ -f "$GITHUB_KEY_PATH" ]]; then
  info "GitHub SSH key already exists at ${GITHUB_KEY_PATH} — skipping generation."
else
  sudo -u "$USERNAME" ssh-keygen -t ed25519 \
    -C "$GITHUB_EMAIL" \
    -f "$GITHUB_KEY_PATH" \
    -N ""
  success "GitHub SSH key pair generated."
fi

# Configure ~/.ssh/config to use this key for GitHub automatically
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

# Store GitHub public key for display at the end
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
# STEP 9 — Install Docker CE (official apt method)
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

# Base directories
mkdir -p "${DOCKER_BASE}"
mkdir -p "${DOCKER_APPDATA}"
mkdir -p "${DOCKER_VOLUMES}"

# Per-stack appdata directories
mkdir -p "${DOCKER_APPDATA}/socket-proxy"
mkdir -p "${DOCKER_APPDATA}/portainer"
mkdir -p "${DOCKER_APPDATA}/dockge"
mkdir -p "${DOCKER_APPDATA}/dockge/stacks"   # Dockge manages stacks from here

success "Directories created."
info "  ${DOCKER_BASE}"
info "  ${DOCKER_APPDATA}"
info "  ${DOCKER_VOLUMES}"
info "  ${DOCKER_APPDATA}/socket-proxy"
info "  ${DOCKER_APPDATA}/portainer"
info "  ${DOCKER_APPDATA}/dockge"
info "  ${DOCKER_APPDATA}/dockge/stacks"

# -----------------------------------------------------------------------------
# STEP 12 — Generate .env file
# -----------------------------------------------------------------------------
header "Generating Docker .env File"

# Resolve PUID and PGID for the user
USER_UID=$(id -u "$USERNAME")
USER_GID=$(id -g "$USERNAME")

cat > "${DOCKER_BASE}/.env" << EOF
# =============================================================================
# Docker Stack Environment Variables
# =============================================================================
# Generated : $(date '+%Y-%m-%d %H:%M:%S')
# Host      : ${NEW_HOSTNAME}
#
# This file is sourced automatically by docker compose from the directory
# where compose.yaml is run, OR referenced explicitly via --env-file.
#
# DO NOT commit this file to version control.
# It is listed in .gitignore for this reason.
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
# Local IP ranges for access control rules (used by Traefik, NGINX PM etc)
LOCAL_IPS=127.0.0.1/32,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12

# -----------------------------------------------------------------------------
# Docker directories
# -----------------------------------------------------------------------------
DOCKERDIR=${DOCKER_BASE}
APPDATA=${DOCKER_APPDATA}
VOLUMES=${DOCKER_VOLUMES}

# -----------------------------------------------------------------------------
# Socket Proxy
# Docker socket proxy endpoint — containers use this instead of raw socket
# -----------------------------------------------------------------------------
DOCKER_HOST=tcp://socket-proxy:2375

# -----------------------------------------------------------------------------
# Container ports
# Add new container ports here as your stack grows
# -----------------------------------------------------------------------------
PORTAINER_PORT=9443
DOCKGE_PORT=5001
EOF

chmod 600 "${DOCKER_BASE}/.env"
chown "${USERNAME}:${USERNAME}" "${DOCKER_BASE}/.env"
success ".env file generated at ${DOCKER_BASE}/.env"

# -----------------------------------------------------------------------------
# STEP 13 — POSIX ACLs
# -----------------------------------------------------------------------------
header "Applying POSIX ACLs"
info "Applying ACLs for '${USERNAME}' (UID=${USER_UID} GID=${USER_GID})..."

chown -R "${USERNAME}:${USERNAME}" "${DOCKER_BASE}"
setfacl -R -m u:"${USERNAME}":rwx "${DOCKER_BASE}"     # Apply to existing items
setfacl -R -d -m u:"${USERNAME}":rwx "${DOCKER_BASE}"  # Default ACL for new items
success "POSIX ACLs applied to ${DOCKER_BASE}."

# -----------------------------------------------------------------------------
# STEP 14 — Deploy Socket Proxy
# -----------------------------------------------------------------------------
header "Deploying Socket Proxy"

# Write compose file
cat > "${DOCKER_APPDATA}/socket-proxy/compose.yaml" << EOF
# =============================================================================
# Socket Proxy
# =============================================================================
# Sits between Docker socket and containers that need Docker API access.
# Prevents direct access to /var/run/docker.sock — improves security by
# exposing only the API endpoints each container actually needs.
#
# Portainer and Dockge connect via tcp://socket-proxy:2375 instead of
# mounting the raw Docker socket directly.
# =============================================================================

networks:
  socket_proxy:
    name: socket_proxy
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.91.0/24  # Internal Docker-only subnet

services:
  socket-proxy:
    image: lscr.io/linuxserver/socket-proxy:latest
    container_name: socket-proxy
    restart: unless-stopped
    networks:
      socket_proxy:
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro  # Read-only mount
    environment:
      # Allow read access for Portainer / Dockge visibility
      - CONTAINERS=1   # List and inspect containers
      - IMAGES=1       # List images
      - INFO=1         # Docker system info
      - NETWORKS=1     # List networks
      - SERVICES=1     # List services
      - TASKS=1        # List tasks
      - VOLUMES=1      # List volumes
      - EVENTS=1       # Stream events (needed for live updates)
      - PING=1         # Health check endpoint
      # Write operations — disabled by default for security
      # Enable only if a specific container requires it
      - POST=0         # Block all write/create/delete operations
EOF

chown -R "${USERNAME}:${USERNAME}" "${DOCKER_APPDATA}/socket-proxy"

# Start socket proxy
docker compose -f "${DOCKER_APPDATA}/socket-proxy/compose.yaml" up -d
success "Socket Proxy deployed."

# -----------------------------------------------------------------------------
# STEP 15 — Deploy Portainer CE
# -----------------------------------------------------------------------------
header "Deploying Portainer CE"

cat > "${DOCKER_APPDATA}/portainer/compose.yaml" << EOF
# =============================================================================
# Portainer CE
# =============================================================================
# Docker management UI — use for monitoring, visibility, and container logs.
# Connects to Docker via Socket Proxy rather than raw Docker socket.
#
# UI: https://${SERVER_LAN_IP}:9443
# Note: Self-signed certificate — browser will show a security warning.
#       This is normal for a local install.
# =============================================================================

networks:
  socket_proxy:
    name: socket_proxy
    external: true  # Joins the network created by socket-proxy stack

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
      - ${DOCKER_APPDATA}/portainer:/data
    environment:
      - DOCKER_HOST=tcp://socket-proxy:2375
    command: --http-disabled  # HTTPS only
EOF

chown -R "${USERNAME}:${USERNAME}" "${DOCKER_APPDATA}/portainer"

docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/portainer/compose.yaml" \
  up -d
success "Portainer CE deployed."

# -----------------------------------------------------------------------------
# STEP 16 — Deploy Dockge
# -----------------------------------------------------------------------------
header "Deploying Dockge"

cat > "${DOCKER_APPDATA}/dockge/compose.yaml" << EOF
# =============================================================================
# Dockge
# =============================================================================
# Compose-file focused Docker management UI.
# Point it at your stacks folder and it shows every compose.yaml as a
# manageable stack — start, stop, edit, logs — all per compose file.
# CLI and Dockge work alongside each other without conflict.
#
# UI: http://${SERVER_LAN_IP}:5001
#
# Stacks folder: ${DOCKER_APPDATA}/dockge/stacks
# Note: For Dockge to manage a stack, place its compose.yaml inside
#       the stacks folder above, not in appdata directly.
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
      - /var/run/docker.sock:/var/run/docker.sock  # Dockge requires direct socket
      - ${DOCKER_APPDATA}/dockge:/app/data
      - ${DOCKER_APPDATA}/dockge/stacks:/opt/stacks  # Where Dockge looks for stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
EOF

chown -R "${USERNAME}:${USERNAME}" "${DOCKER_APPDATA}/dockge"

docker compose \
  --env-file "${DOCKER_BASE}/.env" \
  -f "${DOCKER_APPDATA}/dockge/compose.yaml" \
  up -d
success "Dockge deployed."

# =============================================================================
# STEP 17 — Final summary
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
echo -e "    Socket Proxy    : ${GREEN}running (internal)${RESET}"
echo -e "    Portainer CE    : ${CYAN}https://${MACHINE_IP}:9443${RESET}"
echo -e "    Dockge          : ${CYAN}http://${MACHINE_IP}:5001${RESET}"
echo

# --- SSH login reminder ------------------------------------------------------
if [[ -n "$SSH_PUBKEY" ]]; then
  echo -e "${GREEN}  Passwordless SSH login is configured.${RESET}"
  echo -e "  Connect from Windows: ${CYAN}ssh ${USERNAME}@${MACHINE_IP}${RESET}"
else
  echo -e "${YELLOW}  No SSH public key provided — password login still required.${RESET}"
  echo -e "  To add a key later, paste your public key into:"
  echo -e "  ${CYAN}~/.ssh/authorized_keys${RESET}"
fi
echo

# --- GitHub key instructions -------------------------------------------------
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
echo -e "  Then clone your repo:   ${CYAN}git clone git@github.com:thirsty-fatman/homelab.git${RESET}"
echo

echo -e "${YELLOW}  Other important notes:${RESET}"
echo -e "  - Log out and back in (or reboot) for docker group membership to take effect"
echo -e "  - Portainer uses a self-signed certificate — browser warning is normal"
echo -e "  - Dockge stacks folder: ${DOCKER_APPDATA}/dockge/stacks"
echo -e "  - Deploy other stacks via CLI: cd ${DOCKER_APPDATA}/<service> && docker compose up -d"
echo -e "  - Use ${DOCKER_BASE}/.env as your single source of truth for all stack variables"
echo
