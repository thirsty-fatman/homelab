#!/usr/bin/env bash
# =============================================================================
# Cloudflare DNS Setup Script
# =============================================================================
# Version  : 1.0.2
# Created  : 2026-06-10
# Author   : github.com/thirsty-fatman
# Filename : cloudflare-setup.sh
#
# Changelog:
#   1.0.2 - 2026-06-12 - Fixed "unbound variable" error on CLOUDFLARE_TOKEN
#                         in the .env-saving loop: CLOUDFLARE_TOKEN was never
#                         assigned before "${!var}" indirect expansion tried
#                         to read it under set -u. Added explicit
#                         CLOUDFLARE_TOKEN="${CF_TOKEN}" mapping before the
#                         loop and removed now-redundant duplicate save block.
#   1.0.1 - 2026-06-12 - Fixed "((var++))" arithmetic expressions which exit
#                         non-zero (triggering set -e abort) when var=0 -
#                         the very first increment of any counter starting
#                         at 0. Replaced all with "var=$((var + 1))" form.
#                         This caused npm-setup.sh to silently exit after
#                         processing only the first proxy host.
#   1.0.0 - 2026-06-10 - Initial release
#
# Description:
#   Configures Cloudflare DNS A records for homelab services.
#   Reads SERVER_LAN_IP from /opt/docker/.env if present.
#   Saves CLOUDFLARE_TOKEN, DOMAIN, and ZONE_ID back to .env.
#   Safe to re-run — creates, updates, or skips records as needed.
#   No personal information hardcoded.
#
# What this script does:
#   1. Prompts for Cloudflare API token and domain
#   2. Validates token against Cloudflare API
#   3. Looks up Zone ID for the domain automatically
#   4. Creates or updates DNS A records for each service
#   5. Saves credentials to /opt/docker/.env
#
# Usage:
#   sudo bash cloudflare-setup.sh
#
# Or directly from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/cloudflare-setup.sh -o cloudflare-setup.sh
#   sudo bash cloudflare-setup.sh
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
  error "This script must be run as root. Try: sudo bash cloudflare-setup.sh"
  exit 1
fi

# -----------------------------------------------------------------------------
# Check curl is available
# -----------------------------------------------------------------------------
if ! command -v curl &>/dev/null; then
  error "curl is required but not installed. Run: sudo apt-get install -y curl"
  exit 1
fi

# -----------------------------------------------------------------------------
# Load .env if present
# -----------------------------------------------------------------------------
ENV_FILE="/opt/docker/.env"
SERVER_LAN_IP=""
INSTALL_PORTAINER="n"

if [[ -f "$ENV_FILE" ]]; then
  info "Found ${ENV_FILE} — loading existing values."
  # Source only safe key=value lines
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_]+$ ]] || continue
    [[ -z "$value" ]] && continue
    printf -v "$key" '%s' "$value"
  done < <(grep -E '^[A-Z_]+=.+' "$ENV_FILE")
fi

# -----------------------------------------------------------------------------
# Cloudflare API helper
# -----------------------------------------------------------------------------
cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -s -X "$method" \
      "https://api.cloudflare.com/client/v4/${endpoint}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -s -X "$method" \
      "https://api.cloudflare.com/client/v4/${endpoint}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

# =============================================================================
# STEP 1 — Interactive menu
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "   Cloudflare DNS Setup"
echo "   v1.0.2 | 2026-06-12"
echo "============================================================"
echo -e "${RESET}"
echo -e "This script creates or updates DNS A records in Cloudflare"
echo -e "for your homelab services. Safe to re-run at any time.\n"

# --- Cloudflare API token ----------------------------------------------------
header "Cloudflare API Token"
echo -e "  Generate at: ${CYAN}https://dash.cloudflare.com/profile/api-tokens${RESET}"
echo -e "  Use the ${BOLD}Edit zone DNS${RESET} template scoped to your domain."
echo -e "  Save the token in your password manager — it only shows once.\n"

# Check if token already in .env
EXISTING_TOKEN="${CLOUDFLARE_TOKEN:-}"

while true; do
  if [[ -n "$EXISTING_TOKEN" ]]; then
    echo -e "${BOLD}Cloudflare API token${RESET}"
    echo -e "  A token is already saved in ${ENV_FILE}."
    read -rsp "  Press Enter to use existing token, or paste a new one: " CF_TOKEN_INPUT < /dev/tty
    echo
    if [[ -z "$CF_TOKEN_INPUT" ]]; then
      CF_TOKEN="$EXISTING_TOKEN"
    else
      CF_TOKEN="$CF_TOKEN_INPUT"
    fi
  else
    echo -e "${BOLD}Cloudflare API token${RESET}"
    read -rsp "  Paste token: " CF_TOKEN < /dev/tty
    echo
  fi

  if [[ -z "$CF_TOKEN" ]]; then
    warn "Token cannot be blank. Please try again."
    EXISTING_TOKEN=""
    continue
  fi

  # Validate token
  info "Validating Cloudflare API token..."
  VERIFY_RESPONSE=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json")

  VERIFY_SUCCESS=$(echo "$VERIFY_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")

  if [[ "$VERIFY_SUCCESS" == "True" ]]; then
    success "Cloudflare API token is valid."
    echo
    break
  else
    ERROR_MSG=$(echo "$VERIFY_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['errors'][0]['message'] if d.get('errors') else 'Unknown error')" 2>/dev/null || echo "Unknown error")
    warn "Token validation failed: ${ERROR_MSG}"
    warn "Please check the token and try again."
    EXISTING_TOKEN=""
  fi
done

# --- Domain ------------------------------------------------------------------
header "Domain"
EXISTING_DOMAIN="${DOMAIN:-}"
if [[ -n "$EXISTING_DOMAIN" ]]; then
  echo -e "${BOLD}Domain name${RESET}"
  echo -e "  Current/default: ${YELLOW}${EXISTING_DOMAIN}${RESET}"
  read -rp "  New value (Enter to keep): " DOMAIN_INPUT < /dev/tty
  echo
  DOMAIN="${DOMAIN_INPUT:-$EXISTING_DOMAIN}"
else
  while true; do
    echo -e "${BOLD}Domain name${RESET} (e.g. example.com)"
    read -rp "  Domain: " DOMAIN < /dev/tty
    echo
    if [[ -z "$DOMAIN" ]]; then
      warn "Domain cannot be blank. Please try again."
      continue
    fi
    # Basic domain format validation
    if [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      warn "'${DOMAIN}' does not look like a valid domain name. Please try again."
    fi
  done
fi

# --- Server LAN IP -----------------------------------------------------------
header "Server LAN IP"
DETECTED_IP="${SERVER_LAN_IP:-$(hostname -I | awk '{print $1}')}"

echo -e "${BOLD}Server LAN IP address${RESET}"
echo -e "  Current/default: ${YELLOW}${DETECTED_IP}${RESET}"
read -rp "  New value (Enter to keep): " IP_INPUT < /dev/tty
echo
SERVER_LAN_IP="${IP_INPUT:-$DETECTED_IP}"

# --- Subdomains --------------------------------------------------------------
header "Subdomains to Configure"
echo -e "  The following DNS A records will be created or updated in Cloudflare."
echo -e "  All records point to ${YELLOW}${SERVER_LAN_IP}${RESET} and are set to DNS only (no proxy).\n"

# Build list of subdomains based on what's installed
SUBDOMAINS=("homepage" "dockge" "npm")

# Add portainer if installed
if [[ "${INSTALL_PORTAINER:-n}" == "y" ]] || docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^portainer$"; then
  SUBDOMAINS+=("portainer")
fi

for sub in "${SUBDOMAINS[@]}"; do
  echo -e "  ${CYAN}${sub}.${DOMAIN}${RESET} → ${SERVER_LAN_IP}"
done
echo

# --- Confirmation ------------------------------------------------------------
header "Confirmation Summary"
echo -e "  Cloudflare token  : ${YELLOW}(set — not displayed)${RESET}"
echo -e "  Domain            : ${YELLOW}${DOMAIN}${RESET}"
echo -e "  Server LAN IP     : ${YELLOW}${SERVER_LAN_IP}${RESET}"
echo -e "  Records to manage : ${YELLOW}${SUBDOMAINS[*]}${RESET}"
echo
read -rp "$(echo -e "${BOLD}Proceed? [y/N]: ${RESET}")" CONFIRM < /dev/tty
echo

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  warn "Aborted by user. Nothing has been changed."
  exit 0
fi

# =============================================================================
# From here everything runs unattended
# =============================================================================

# -----------------------------------------------------------------------------
# STEP 2 — Get Zone ID
# -----------------------------------------------------------------------------
header "Looking Up Zone ID"
info "Finding Zone ID for ${DOMAIN}..."

ZONES_RESPONSE=$(cf_api GET "zones?name=${DOMAIN}&status=active")
ZONE_ID=$(echo "$ZONES_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('success') and d.get('result'):
    print(d['result'][0]['id'])
" 2>/dev/null || echo "")

if [[ -z "$ZONE_ID" ]]; then
  error "Could not find an active zone for '${DOMAIN}' in this Cloudflare account."
  error "Make sure the domain is added to Cloudflare and the nameservers are active."
  exit 1
fi

success "Zone ID found: ${ZONE_ID}"

# -----------------------------------------------------------------------------
# STEP 3 — Create or update DNS records
# -----------------------------------------------------------------------------
header "Configuring DNS Records"

CREATED=0
UPDATED=0
SKIPPED=0

for SUBDOMAIN in "${SUBDOMAINS[@]}"; do
  FQDN="${SUBDOMAIN}.${DOMAIN}"
  info "Checking ${FQDN}..."

  # Check if record exists
  EXISTING=$(cf_api GET "zones/${ZONE_ID}/dns_records?type=A&name=${FQDN}")
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
    'content': '${SERVER_LAN_IP}',
    'ttl': 1,
    'proxied': False
}))
")

  if [[ -z "$EXISTING_ID" ]]; then
    # Record does not exist — create it
    CREATE_RESPONSE=$(cf_api POST "zones/${ZONE_ID}/dns_records" "$RECORD_DATA")
    CREATE_SUCCESS=$(echo "$CREATE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
    if [[ "$CREATE_SUCCESS" == "True" ]]; then
      success "Created: ${FQDN} → ${SERVER_LAN_IP}"
      CREATED=$((CREATED + 1))
    else
      ERROR_MSG=$(echo "$CREATE_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['errors'][0]['message'] if d.get('errors') else 'Unknown error')" 2>/dev/null || echo "Unknown error")
      warn "Failed to create ${FQDN}: ${ERROR_MSG}"
    fi
  elif [[ "$EXISTING_IP" == "$SERVER_LAN_IP" ]]; then
    # Record exists with correct IP — skip
    success "Already correct: ${FQDN} → ${SERVER_LAN_IP} (skipped)"
    SKIPPED=$((SKIPPED + 1))
  else
    # Record exists with different IP — update it
    UPDATE_RESPONSE=$(cf_api PUT "zones/${ZONE_ID}/dns_records/${EXISTING_ID}" "$RECORD_DATA")
    UPDATE_SUCCESS=$(echo "$UPDATE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
    if [[ "$UPDATE_SUCCESS" == "True" ]]; then
      success "Updated: ${FQDN} → ${SERVER_LAN_IP} (was ${EXISTING_IP})"
      UPDATED=$((UPDATED + 1))
    else
      ERROR_MSG=$(echo "$UPDATE_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['errors'][0]['message'] if d.get('errors') else 'Unknown error')" 2>/dev/null || echo "Unknown error")
      warn "Failed to update ${FQDN}: ${ERROR_MSG}"
    fi
  fi
done

# -----------------------------------------------------------------------------
# STEP 4 — Save to .env
# -----------------------------------------------------------------------------
header "Saving to .env"

# Map CF_TOKEN (used throughout this script) to the .env variable name
CLOUDFLARE_TOKEN="${CF_TOKEN}"

if [[ -f "$ENV_FILE" ]]; then
  # Update or append each variable
  for var in CLOUDFLARE_TOKEN DOMAIN ZONE_ID SERVER_LAN_IP; do
    value="${!var}"
    if grep -q "^${var}=" "$ENV_FILE"; then
      sed -i "s|^${var}=.*|${var}=${value}|" "$ENV_FILE"
    else
      echo "${var}=${value}" >> "$ENV_FILE"
    fi
  done
  success "Updated ${ENV_FILE}"
else
  warn "${ENV_FILE} not found — creating minimal .env"
  cat > "$ENV_FILE" << EOF
CLOUDFLARE_TOKEN=${CF_TOKEN}
DOMAIN=${DOMAIN}
ZONE_ID=${ZONE_ID}
SERVER_LAN_IP=${SERVER_LAN_IP}
EOF
  chmod 600 "$ENV_FILE"
fi

success "Cloudflare credentials saved to ${ENV_FILE}"

# =============================================================================
# Final summary
# =============================================================================
echo
echo -e "${BOLD}${GREEN}"
echo "============================================================"
echo "   Cloudflare DNS Setup Complete"
echo "============================================================"
echo -e "${RESET}"
echo -e "  Domain            : ${GREEN}${DOMAIN}${RESET}"
echo -e "  Zone ID           : ${GREEN}${ZONE_ID}${RESET}"
echo -e "  Server LAN IP     : ${GREEN}${SERVER_LAN_IP}${RESET}"
echo
echo -e "  Records created   : ${GREEN}${CREATED}${RESET}"
echo -e "  Records updated   : ${GREEN}${UPDATED}${RESET}"
echo -e "  Records skipped   : ${GREEN}${SKIPPED}${RESET} (already correct)"
echo
echo -e "  DNS records are set to ${YELLOW}DNS only${RESET} (grey cloud — no Cloudflare proxy)."
echo -e "  This is correct for local LAN access."
echo
echo -e "${YELLOW}  Next step:${RESET}"
echo -e "  Run NPM setup to configure SSL certificate and proxy hosts:"
echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/npm-setup.sh -o npm-setup.sh${RESET}"
echo -e "  ${CYAN}sudo bash npm-setup.sh${RESET}"
echo
