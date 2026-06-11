#!/usr/bin/env bash
# =============================================================================
# NGINX Proxy Manager Setup Script
# =============================================================================
# Version  : 1.2.0
# Created  : 2026-06-10
# Author   : github.com/thirsty-fatman
#
# Changelog:
#   1.2.0 - 2026-06-11 - Fixed: removed invalid "expiry" field from all
#                         /api/tokens auth requests (NPM 2.15+ rejects it
#                         with "data must NOT have additional properties").
#                         NPM 2.15+ has no default admin@example.com/changeme
#                         account — added upfront instructions to complete
#                         NPM's web UI first-run setup before running this
#                         script, and updated error message accordingly.
#   1.1.0 - 2026-06-10 - Fixed authentication order. Added targeted
#                         services.yaml URL update after proxy hosts created.
#   1.0.0 - 2026-06-10 - Initial release
#
# Description:
#   Configures NGINX Proxy Manager via its REST API:
#   - Changes default admin credentials
#   - Creates wildcard SSL certificate via Cloudflare DNS challenge
#   - Creates proxy hosts for all core services
#   Reads DOMAIN, SERVER_LAN_IP, CLOUDFLARE_TOKEN from /opt/docker/.env.
#   If not found in .env, prompts for them and saves them.
#   Safe to re-run — creates, updates, or skips as needed.
#   No personal information hardcoded.
#
# What this script does:
#   1. Reads or prompts for domain, server IP, Cloudflare token
#   2. Waits for NPM API to be healthy (up to 60 seconds)
#   3. Authenticates with NPM default credentials
#   4. Changes admin email and password
#   5. Creates wildcard SSL certificate via Cloudflare DNS challenge
#   6. Waits for certificate to be issued (up to 120 seconds)
#   7. Creates proxy hosts for all core services
#
# Usage:
#   sudo bash npm-setup.sh
#
# Or directly from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/npm-setup.sh -o npm-setup.sh
#   sudo bash npm-setup.sh
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
  error "This script must be run as root. Try: sudo bash npm-setup.sh"
  exit 1
fi

# -----------------------------------------------------------------------------
# Check dependencies
# -----------------------------------------------------------------------------
for cmd in curl python3 docker; do
  if ! command -v "$cmd" &>/dev/null; then
    error "${cmd} is required but not installed."
    exit 1
  fi
done

# -----------------------------------------------------------------------------
# Load .env if present
# -----------------------------------------------------------------------------
ENV_FILE="/opt/docker/.env"
NPM_URL="http://127.0.0.1:81"

if [[ -f "$ENV_FILE" ]]; then
  info "Found ${ENV_FILE} — loading existing values."
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_]+$ ]] || continue
    [[ -z "$value" ]] && continue
    printf -v "$key" '%s' "$value" 2>/dev/null || true
  done < <(grep -E '^[A-Z_]+=.+' "$ENV_FILE")
fi

# -----------------------------------------------------------------------------
# NPM API helpers
# -----------------------------------------------------------------------------
npm_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local token="${4:-}"

  local auth_header=""
  if [[ -n "$token" ]]; then
    auth_header="-H \"Authorization: Bearer ${token}\""
  fi

  if [[ -n "$data" ]]; then
    eval curl -s -X "$method" \
      "${NPM_URL}/api/${endpoint}" \
      -H "Content-Type: application/json" \
      ${auth_header} \
      --data "'${data}'"
  else
    eval curl -s -X "$method" \
      "${NPM_URL}/api/${endpoint}" \
      -H "Content-Type: application/json" \
      ${auth_header}
  fi
}

npm_api_auth() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -s -X "$method" \
      "${NPM_URL}/api/${endpoint}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${NPM_TOKEN}" \
      --data "$data"
  else
    curl -s -X "$method" \
      "${NPM_URL}/api/${endpoint}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${NPM_TOKEN}"
  fi
}

# =============================================================================
# STEP 1 — Interactive menu
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "   NGINX Proxy Manager Setup"
echo "   v1.0.0 | 2026-06-10"
echo "============================================================"
echo -e "${RESET}"
echo -e "This script configures NPM via its API — sets admin credentials,"
echo -e "creates a wildcard SSL certificate, and sets up proxy hosts.\n"

# --- Check for required values from .env -------------------------------------
header "Required Configuration"

# Domain
if [[ -z "${DOMAIN:-}" ]]; then
  warn "DOMAIN not found in ${ENV_FILE}."
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
else
  echo -e "${BOLD}Domain${RESET}"
  echo -e "  Current/default: ${YELLOW}${DOMAIN}${RESET}"
  read -rp "  New value (Enter to keep): " DOMAIN_INPUT < /dev/tty
  echo
  DOMAIN="${DOMAIN_INPUT:-$DOMAIN}"
fi

# Server LAN IP
if [[ -z "${SERVER_LAN_IP:-}" ]]; then
  warn "SERVER_LAN_IP not found in ${ENV_FILE}."
  DETECTED_IP=$(hostname -I | awk '{print $1}')
  echo -e "${BOLD}Server LAN IP${RESET}"
  echo -e "  Current/default: ${YELLOW}${DETECTED_IP}${RESET}"
  read -rp "  New value (Enter to keep): " IP_INPUT < /dev/tty
  echo
  SERVER_LAN_IP="${IP_INPUT:-$DETECTED_IP}"
else
  echo -e "${BOLD}Server LAN IP${RESET}"
  echo -e "  Current/default: ${YELLOW}${SERVER_LAN_IP}${RESET}"
  read -rp "  New value (Enter to keep): " IP_INPUT < /dev/tty
  echo
  SERVER_LAN_IP="${IP_INPUT:-$SERVER_LAN_IP}"
fi

# Cloudflare token
if [[ -z "${CLOUDFLARE_TOKEN:-}" ]]; then
  warn "CLOUDFLARE_TOKEN not found in ${ENV_FILE}."
  echo -e "${BOLD}Cloudflare API token${RESET}"
  echo -e "  Generate at: ${CYAN}https://dash.cloudflare.com/profile/api-tokens${RESET}"
  echo -e "  Use the ${BOLD}Edit zone DNS${RESET} template scoped to your domain.\n"
  while true; do
    read -rsp "  Paste token: " CLOUDFLARE_TOKEN < /dev/tty
    echo
    if [[ -z "$CLOUDFLARE_TOKEN" ]]; then
      warn "Token cannot be blank. Please try again."
      continue
    fi
    # Validate token
    info "Validating Cloudflare API token..."
    VERIFY=$(curl -s -X GET \
      "https://api.cloudflare.com/client/v4/user/tokens/verify" \
      -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
      -H "Content-Type: application/json")
    VERIFY_OK=$(echo "$VERIFY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))" 2>/dev/null || echo "False")
    if [[ "$VERIFY_OK" == "True" ]]; then
      success "Cloudflare API token is valid."
      echo
      break
    else
      warn "Token validation failed. Please check and try again."
    fi
  done
else
  info "Cloudflare token found in ${ENV_FILE}."
fi

# --- NPM admin credentials ---------------------------------------------------
header "NPM Admin Credentials"
echo -e "  ${BOLD}NPM 2.15+ requires first-time setup via the web UI${RESET} — there is no"
echo -e "  default admin@example.com / changeme account to authenticate against."
echo -e ""
echo -e "  If you haven't already, open ${CYAN}http://${SERVER_LAN_IP:-<server-ip>}:81${RESET} in a browser"
echo -e "  now and complete the first-run form (name, email, password)."
echo -e ""
echo -e "  Enter the SAME email and password you used (or will use) there below —"
echo -e "  this script authenticates with those credentials.\n"

echo -e "${BOLD}Admin email address${RESET}"
read -rp "  Email: " NPM_EMAIL < /dev/tty
echo

# Password
while true; do
  echo -e "${BOLD}Admin password${RESET}"
  read -rsp "  Enter password: " NPM_PASS1 < /dev/tty
  echo
  if [[ ${#NPM_PASS1} -lt 8 ]]; then
    warn "Password must be at least 8 characters. Please try again."
    continue
  fi
  read -rsp "  Confirm password: " NPM_PASS2 < /dev/tty
  echo
  if [[ "$NPM_PASS1" == "$NPM_PASS2" ]]; then
    NPM_PASSWORD="$NPM_PASS1"
    NPM_PASS1=""
    NPM_PASS2=""
    echo
    break
  else
    warn "Passwords do not match. Please try again."
  fi
done

# Check if portainer is running
INSTALL_PORTAINER="n"
if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^portainer$"; then
  INSTALL_PORTAINER="y"
fi

# --- Confirmation ------------------------------------------------------------
header "Confirmation Summary"
echo -e "  Domain            : ${YELLOW}${DOMAIN}${RESET}"
echo -e "  Server LAN IP     : ${YELLOW}${SERVER_LAN_IP}${RESET}"
echo -e "  Cloudflare token  : ${YELLOW}(set — not displayed)${RESET}"
echo -e "  NPM admin email   : ${YELLOW}${NPM_EMAIL}${RESET}"
echo -e "  NPM admin password: ${YELLOW}(set — not displayed)${RESET}"
echo
echo -e "  Proxy hosts to create:"
echo -e "    https://homepage.${DOMAIN}  → ${SERVER_LAN_IP}:3000"
echo -e "    https://dockge.${DOMAIN}    → ${SERVER_LAN_IP}:5001"
echo -e "    https://npm.${DOMAIN}       → 127.0.0.1:81"
if [[ "$INSTALL_PORTAINER" == "y" ]]; then
  echo -e "    https://portainer.${DOMAIN} → ${SERVER_LAN_IP}:9443"
fi
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
# STEP 2 — Save missing values to .env
# -----------------------------------------------------------------------------
header "Updating .env"

if [[ -f "$ENV_FILE" ]]; then
  for var in DOMAIN SERVER_LAN_IP CLOUDFLARE_TOKEN; do
    value="${!var}"
    if grep -q "^${var}=" "$ENV_FILE"; then
      sed -i "s|^${var}=.*|${var}=${value}|" "$ENV_FILE"
    else
      echo "${var}=${value}" >> "$ENV_FILE"
    fi
  done
  success "Updated ${ENV_FILE}"
fi

# -----------------------------------------------------------------------------
# STEP 3 — Wait for NPM to be healthy
# -----------------------------------------------------------------------------
header "Waiting for NPM to be Ready"
info "Polling NPM API health endpoint (max 60 seconds)..."

ATTEMPTS=0
MAX_ATTEMPTS=12
until curl -s "${NPM_URL}/api/" &>/dev/null; do
  ((ATTEMPTS++))
  if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
    error "NPM did not become ready within 60 seconds."
    error "Check if the nginx-proxy-manager container is running: docker ps"
    exit 1
  fi
  info "Waiting for NPM... (attempt ${ATTEMPTS}/${MAX_ATTEMPTS})"
  sleep 5
done
success "NPM is ready."

# -----------------------------------------------------------------------------
# STEP 4 — Authenticate with NPM
# -----------------------------------------------------------------------------
header "Authenticating with NPM"

# Try supplied credentials first — handles case where credentials already changed
info "Logging in with supplied credentials..."
AUTH_RESPONSE=$(curl -s -X POST \
  "${NPM_URL}/api/tokens" \
  -H "Content-Type: application/json" \
  --data "{\"identity\":\"${NPM_EMAIL}\",\"secret\":\"${NPM_PASSWORD}\"}")

NPM_TOKEN=$(echo "$AUTH_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('token', ''))
" 2>/dev/null || echo "")

if [[ -n "$NPM_TOKEN" ]]; then
  success "Authenticated with supplied credentials — skipping credential update."
  SKIP_CRED_UPDATE=true
else
  # Fall back to default credentials
  info "Supplied credentials failed — trying default credentials..."
  AUTH_RESPONSE=$(curl -s -X POST \
    "${NPM_URL}/api/tokens" \
    -H "Content-Type: application/json" \
    --data '{"identity":"admin@example.com","secret":"changeme"}')

  NPM_TOKEN=$(echo "$AUTH_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('token', ''))
" 2>/dev/null || echo "")

  if [[ -z "$NPM_TOKEN" ]]; then
    error "Could not authenticate with NPM using supplied or default credentials."
    error ""
    error "If this is a fresh NPM install (2.15+), it has no default account."
    error "Open http://${SERVER_LAN_IP}:81 in a browser and complete the"
    error "first-run setup form, then re-run this script using the SAME"
    error "email and password you entered there."
    exit 1
  fi
  success "Authenticated with default credentials."
  SKIP_CRED_UPDATE=false
fi

# -----------------------------------------------------------------------------
# STEP 5 — Update admin credentials
# -----------------------------------------------------------------------------
if [[ "$SKIP_CRED_UPDATE" == false ]]; then
  header "Updating Admin Credentials"

  # Get current user ID
  USERS_RESPONSE=$(npm_api_auth GET "users")
  USER_ID=$(echo "$USERS_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if isinstance(d, list) and d:
    print(d[0].get('id', 1))
else:
    print(1)
" 2>/dev/null || echo "1")

  # Update email and name
  UPDATE_RESPONSE=$(npm_api_auth PUT "users/${USER_ID}" \
    "{\"name\":\"Admin\",\"nickname\":\"Admin\",\"email\":\"${NPM_EMAIL}\",\"roles\":[\"admin\"]}")

  UPDATE_OK=$(echo "$UPDATE_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('id' in d)
" 2>/dev/null || echo "False")

  if [[ "$UPDATE_OK" == "True" ]]; then
    success "Admin email updated to ${NPM_EMAIL}"
  else
    warn "Could not update admin email — continuing anyway."
  fi

  # Update password
  PASS_RESPONSE=$(npm_api_auth PUT "users/${USER_ID}/auth" \
    "{\"type\":\"password\",\"current\":\"changeme\",\"secret\":\"${NPM_PASSWORD}\"}")

  PASS_OK=$(echo "$PASS_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('id' in d)
" 2>/dev/null || echo "False")

  if [[ "$PASS_OK" == "True" ]]; then
    success "Admin password updated."
    NPM_PASSWORD=""
  else
    warn "Could not update admin password — continuing anyway."
  fi

  # Re-authenticate with new credentials
  info "Re-authenticating with new credentials..."
  AUTH_RESPONSE=$(curl -s -X POST \
    "${NPM_URL}/api/tokens" \
    -H "Content-Type: application/json" \
    --data "{\"identity\":\"${NPM_EMAIL}\",\"secret\":\"${NPM_PASSWORD}\"}")

  NPM_TOKEN=$(echo "$AUTH_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('token', ''))
" 2>/dev/null || echo "")

  if [[ -z "$NPM_TOKEN" ]]; then
    warn "Could not re-authenticate — proceeding with original token."
  else
    success "Re-authenticated successfully."
  fi
fi

# -----------------------------------------------------------------------------
# STEP 6 — Create wildcard SSL certificate
# -----------------------------------------------------------------------------
header "Creating Wildcard SSL Certificate"

# Check if cert already exists
CERTS_RESPONSE=$(npm_api_auth GET "nginx/certificates")
CERT_ID=$(echo "$CERTS_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if isinstance(d, list):
    for cert in d:
        domains = cert.get('domain_names', [])
        if '*.${DOMAIN}' in domains:
            print(cert.get('id', ''))
            break
" 2>/dev/null || echo "")

if [[ -n "$CERT_ID" ]]; then
  success "Wildcard certificate for *.${DOMAIN} already exists (ID: ${CERT_ID}) — skipping."
else
  info "Requesting wildcard certificate for *.${DOMAIN} via Cloudflare DNS challenge..."

  CERT_DATA=$(python3 -c "
import json
print(json.dumps({
    'provider': 'letsencrypt',
    'domain_names': ['*.${DOMAIN}'],
    'meta': {
        'letsencrypt_email': '${NPM_EMAIL}',
        'letsencrypt_agree': True,
        'dns_challenge': True,
        'dns_provider': 'cloudflare',
        'dns_provider_credentials': 'dns_cloudflare_api_token=${CLOUDFLARE_TOKEN}',
        'propagation_seconds': ''
    }
}))
")

  CERT_RESPONSE=$(npm_api_auth POST "nginx/certificates" "$CERT_DATA")
  CERT_ID=$(echo "$CERT_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('id', ''))
" 2>/dev/null || echo "")

  if [[ -z "$CERT_ID" ]]; then
    error "Failed to request SSL certificate."
    ERROR_MSG=$(echo "$CERT_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('error', {}).get('message', 'Unknown error'))
" 2>/dev/null || echo "Unknown error")
    error "Error: ${ERROR_MSG}"
    exit 1
  fi

  # Wait for certificate to be issued
  info "Waiting for certificate to be issued (max 120 seconds)..."
  CERT_ATTEMPTS=0
  CERT_MAX=24

  while true; do
    ((CERT_ATTEMPTS++))
    if [[ $CERT_ATTEMPTS -ge $CERT_MAX ]]; then
      error "Certificate was not issued within 120 seconds."
      error "Check NPM logs: docker logs nginx-proxy-manager"
      exit 1
    fi

    CERT_STATUS=$(npm_api_auth GET "nginx/certificates/${CERT_ID}")
    CERT_VALID=$(echo "$CERT_STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('meta', {}).get('letsencrypt_email', '') != '' and 'expires_on' in d)
" 2>/dev/null || echo "False")

    if [[ "$CERT_VALID" == "True" ]]; then
      success "Wildcard certificate issued successfully (ID: ${CERT_ID})"
      break
    fi

    info "Certificate pending... (attempt ${CERT_ATTEMPTS}/${CERT_MAX})"
    sleep 5
  done
fi

# -----------------------------------------------------------------------------
# STEP 7 — Create proxy hosts
# -----------------------------------------------------------------------------
header "Creating Proxy Hosts"

# Define proxy hosts
# Format: "subdomain|forward_host|forward_port|scheme"
PROXY_HOSTS=(
  "homepage|${SERVER_LAN_IP}|3000|http"
  "dockge|${SERVER_LAN_IP}|5001|http"
  "npm|127.0.0.1|81|http"
)

if [[ "$INSTALL_PORTAINER" == "y" ]]; then
  PROXY_HOSTS+=("portainer|${SERVER_LAN_IP}|9443|https")
fi

CREATED=0
SKIPPED=0

for HOST_DEF in "${PROXY_HOSTS[@]}"; do
  IFS='|' read -r SUBDOMAIN FORWARD_HOST FORWARD_PORT SCHEME <<< "$HOST_DEF"
  FQDN="${SUBDOMAIN}.${DOMAIN}"

  info "Checking proxy host for ${FQDN}..."

  # Check if proxy host already exists
  HOSTS_RESPONSE=$(npm_api_auth GET "nginx/proxy-hosts")
  EXISTING_HOST_ID=$(echo "$HOSTS_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if isinstance(d, list):
    for host in d:
        if '${FQDN}' in host.get('domain_names', []):
            print(host.get('id', ''))
            break
" 2>/dev/null || echo "")

  if [[ -n "$EXISTING_HOST_ID" ]]; then
    success "Already exists: ${FQDN} (skipped)"
    ((SKIPPED++))
    continue
  fi

  # Build proxy host data
  HOST_DATA=$(python3 -c "
import json
print(json.dumps({
    'domain_names': ['${FQDN}'],
    'forward_host': '${FORWARD_HOST}',
    'forward_port': ${FORWARD_PORT},
    'forward_scheme': '${SCHEME}',
    'access_list_id': 0,
    'certificate_id': ${CERT_ID},
    'ssl_forced': True,
    'http2_support': True,
    'block_exploits': True,
    'allow_websocket_upgrade': True,
    'enabled': True
}))
")

  CREATE_RESPONSE=$(npm_api_auth POST "nginx/proxy-hosts" "$HOST_DATA")
  NEW_ID=$(echo "$CREATE_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('id', ''))
" 2>/dev/null || echo "")

  if [[ -n "$NEW_ID" ]]; then
    success "Created: https://${FQDN} → ${SCHEME}://${FORWARD_HOST}:${FORWARD_PORT}"
    ((CREATED++))
  else
    ERROR_MSG=$(echo "$CREATE_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('error', {}).get('message', 'Unknown error'))
" 2>/dev/null || echo "Unknown error")
    warn "Failed to create proxy host for ${FQDN}: ${ERROR_MSG}"
  fi
done


# =============================================================================
# STEP 8 — Update Homepage services.yaml with domain URLs
# =============================================================================
header "Updating Homepage services.yaml"

SERVICES_FILE="/opt/docker/appdata/homepage/config/services.yaml"

if [[ ! -f "$SERVICES_FILE" ]]; then
  warn "Homepage services.yaml not found at ${SERVICES_FILE} — skipping URL update."
else
  info "Updating IP:port URLs to domain URLs (preserving manual overrides)..."

  # Use python3 to do targeted line-by-line replacement
  # Only replaces href values that still contain an IP address
  # Preserves any manually set domain URLs
  python3 - "${SERVICES_FILE}" "${DOMAIN}" << 'PYEOF'
import re, sys

services_file = sys.argv[1]
domain = sys.argv[2]

service_urls = {
    'homepage': 'https://homepage.' + domain,
    'dockge': 'https://dockge.' + domain,
    'nginx-proxy-manager': 'https://npm.' + domain,
    'portainer': 'https://portainer.' + domain,
}

with open(services_file, 'r') as f:
    lines = f.readlines()

updated = 0
current_container = None
new_lines = []

for line in lines:
    container_match = re.search(r'container:\s*(\S+)', line)
    if container_match:
        current_container = container_match.group(1)

    href_ip_match = re.match(r'^(\s+href:\s+)https?://(\d{1,3}\.){3}\d{1,3}(:\d+)?', line)
    if href_ip_match and current_container and current_container in service_urls:
        new_url = service_urls[current_container]
        new_line = re.sub(r'href:\s+\S+', 'href: ' + new_url, line)
        if new_line != line:
            new_lines.append(new_line)
            updated += 1
            continue

    new_lines.append(line)

with open(services_file, 'w') as f:
    f.writelines(new_lines)

print(f'Updated {updated} href(s) to domain URLs.')
PYEOF

  if [[ $? -eq 0 ]]; then
    success "Homepage services.yaml updated with domain URLs."
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^homepage$"; then
      docker restart homepage
      success "Homepage restarted to apply URL changes."
    fi
  else
    warn "Could not update services.yaml — update manually if needed."
  fi
fi


# =============================================================================
# Final summary
# =============================================================================
echo
echo -e "${BOLD}${GREEN}"
echo "============================================================"
echo "   NPM Setup Complete"
echo "============================================================"
echo -e "${RESET}"
echo -e "  Domain            : ${GREEN}${DOMAIN}${RESET}"
echo -e "  SSL certificate   : ${GREEN}*.${DOMAIN}${RESET}"
echo -e "  Proxy hosts created: ${GREEN}${CREATED}${RESET}"
echo -e "  Proxy hosts skipped: ${GREEN}${SKIPPED}${RESET} (already existed)"
echo
echo -e "  Your services are now available at:"
echo -e "    ${CYAN}https://homepage.${DOMAIN}${RESET}"
echo -e "    ${CYAN}https://dockge.${DOMAIN}${RESET}"
echo -e "    ${CYAN}https://npm.${DOMAIN}${RESET}"
if [[ "$INSTALL_PORTAINER" == "y" ]]; then
  echo -e "    ${CYAN}https://portainer.${DOMAIN}${RESET}"
fi
echo
echo -e "${YELLOW}  Important notes:${RESET}"
echo -e "  - Add local DNS records in your router pointing each subdomain to ${SERVER_LAN_IP}"
echo -e "  - Update Homepage services.yaml to use https:// domain URLs instead of IP:port"
echo -e "  - NPM admin UI: ${CYAN}https://npm.${DOMAIN}${RESET}"
echo
