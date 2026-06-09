#!/usr/bin/env bash
# =============================================================================
# Ubuntu Server 24.04 - Post-Install Setup Script
# =============================================================================
# Version  : 1.1.0
# Created  : 2026-06-09
# Author   : github.com/thirsty-fatman
#
# Changelog:
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
#   3.  Runs apt update + upgrade
#   4.  Installs prerequisite packages
#   5.  Installs Docker CE (official apt method)
#   6.  Adds user to docker group
#   7.  Creates Docker directory structure
#   8.  Applies POSIX ACLs on Docker directories
#   9.  Configures Docker log limits
#   10. Installs Portainer CE (monitoring/visibility, port 9443)
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

# =============================================================================
# STEP 1 — Interactive menu
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "   Ubuntu Server 24.04 - Post-Install Setup"
echo "   v1.1.0 | 2026-06-09"
echo "============================================================"
echo -e "${RESET}"
echo -e "For each question, press ${YELLOW}Enter${RESET} to accept the default,"
echo -e "or type a new value and press Enter.\n"

# --- Hostname ----------------------------------------------------------------
header "System Settings"
CURRENT_HOSTNAME=$(hostname)
prompt_default NEW_HOSTNAME "Hostname" "$CURRENT_HOSTNAME"

# --- Username ----------------------------------------------------------------
# Asked twice with no default — catches typos, no personal info hardcoded
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

echo -e "  Docker base       : ${YELLOW}${DOCKER_BASE}${RESET}"
echo -e "  Appdata directory : ${YELLOW}${DOCKER_APPDATA}${RESET}"
echo -e "  Volumes directory : ${YELLOW}${DOCKER_VOLUMES}${RESET}"
echo
echo -e "  Actions to be performed:"
echo -e "    - Set hostname to ${YELLOW}${NEW_HOSTNAME}${RESET}"
echo -e "    - apt update + upgrade"
echo -e "    - Install prerequisite packages"
echo -e "    - Install Docker CE (official apt method)"
echo -e "    - Add ${YELLOW}${USERNAME}${RESET} to docker group"
echo -e "    - Create Docker directory structure with POSIX ACLs"
echo -e "    - Configure Docker log limits (10MB / 3 files)"
echo -e "    - Install Portainer CE (port 9443)"
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

# Update /etc/hosts
if grep -q "127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
else
  echo -e "127.0.1.1\t${NEW_HOSTNAME}" >> /etc/hosts
fi
success "Hostname set to: ${NEW_HOSTNAME}"

# -----------------------------------------------------------------------------
# STEP 4 — Create user if needed
# -----------------------------------------------------------------------------
header "User Account"
if [[ "$USER_EXISTS" == false ]]; then
  info "Creating user '${USERNAME}'..."
  useradd -m -s /bin/bash "$USERNAME"

  # Set password via stdin — password never exposed in process list or logs
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
# STEP 5 — apt update + upgrade
# -----------------------------------------------------------------------------
header "System Update"
info "Running apt update..."
apt-get update -y
info "Running apt upgrade..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
success "System updated."

# -----------------------------------------------------------------------------
# STEP 6 — Install prerequisites
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
# STEP 7 — Install Docker CE (official apt method)
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
# STEP 8 — Configure Docker log limits
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
# STEP 9 — Create Docker directory structure
# -----------------------------------------------------------------------------
header "Creating Docker Directory Structure"
mkdir -p "${DOCKER_BASE}"
mkdir -p "${DOCKER_APPDATA}"
mkdir -p "${DOCKER_VOLUMES}"
success "Directories created:"
info "  ${DOCKER_BASE}"
info "  ${DOCKER_APPDATA}"
info "  ${DOCKER_VOLUMES}"

# -----------------------------------------------------------------------------
# STEP 10 — POSIX ACLs
# -----------------------------------------------------------------------------
header "Applying POSIX ACLs"
USER_UID=$(id -u "$USERNAME")
USER_GID=$(id -g "$USERNAME")
info "Applying ACLs for '${USERNAME}' (UID=${USER_UID} GID=${USER_GID})..."

chown -R "${USERNAME}:${USERNAME}" "${DOCKER_BASE}"
setfacl -R -m u:"${USERNAME}":rwx "${DOCKER_BASE}"     # Apply to existing items
setfacl -R -d -m u:"${USERNAME}":rwx "${DOCKER_BASE}"  # Default ACL for new items
success "POSIX ACLs applied to ${DOCKER_BASE}."

# -----------------------------------------------------------------------------
# STEP 11 — Install Portainer CE
# -----------------------------------------------------------------------------
header "Installing Portainer CE"
PORTAINER_DATA="${DOCKER_APPDATA}/portainer"
mkdir -p "$PORTAINER_DATA"

info "Pulling and starting Portainer CE container..."
docker run -d \
  --name portainer \
  --restart=always \
  -p 8000:8000 \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${PORTAINER_DATA}:/data" \
  portainer/portainer-ce:latest
success "Portainer CE installed and running."

# =============================================================================
# STEP 12 — Final summary
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
echo -e "  Docker base       : ${GREEN}${DOCKER_BASE}${RESET}"
echo -e "  Appdata directory : ${GREEN}${DOCKER_APPDATA}${RESET}"
echo -e "  Volumes directory : ${GREEN}${DOCKER_VOLUMES}${RESET}"
echo -e "  Machine IP        : ${GREEN}${MACHINE_IP}${RESET}"
echo
echo -e "  Portainer UI      : ${CYAN}https://${MACHINE_IP}:9443${RESET}"
echo
echo -e "${YELLOW}  Important notes:${RESET}"
echo -e "  - Log out and back in (or reboot) for docker group membership to take effect"
echo -e "  - Portainer uses a self-signed certificate — your browser will warn, this is normal"
echo -e "  - Deploy stacks via CLI: cd ${DOCKER_APPDATA}/<service> && docker compose up -d"
echo -e "  - Portainer is for monitoring only — manage your stacks via CLI compose files"
echo
