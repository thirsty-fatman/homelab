#!/bin/bash
# ha-setup.sh v1.0.5
# Sets up Home Assistant (Docker) on OSAN via macvlan on IoT VLAN (192.168.8.x)
# Independent of server-setup.sh / cloudflare-setup.sh / npm-setup.sh
# Local access only for now: http://192.168.8.2:8123
#
# CHANGELOG:
# v1.0.5 - chmod 600 on netplan VLAN config (fixes "too open" warning).
#          Remove stale container before docker compose up if it references
#          a since-removed/recreated network (fixes "network ... not found"
#          error when iot_macvlan is recreated with a new ID).
# v1.0.4 - Fixed VLAN tagging: macvlan parent must be a VLAN 8 sub-interface
#          (eno1.8), not eno1 directly. eno1 carries native/untagged VLAN
#          (4.x); without tagging, macvlan traffic for 192.168.8.x never
#          reaches the UniFi gateway for VLAN 8. Added persistent netplan
#          config for eno1.8, and removes/recreates iot_macvlan + shim with
#          the correct parent if they exist from a prior run.
# v1.0.3 - Initial macvlan + shim + pinned HA container (2026.1.0)

set -e

# --- Network setup: macvlan for IoT VLAN (192.168.8.x) ---

IOT_SUBNET="192.168.8.0/24"
IOT_GATEWAY="192.168.8.1"
PARENT_IF="eno1"
VLAN_ID="8"
VLAN_IF="${PARENT_IF}.${VLAN_ID}"
MACVLAN_NET="iot_macvlan"
SHIM_IF="iot-shim"
SHIM_IP="192.168.8.3/32"
SHIM_NAME="osan-shimnet"
NETPLAN_FILE="/etc/netplan/90-vlan8.yaml"

HA_IP="192.168.8.2"
HA_APPDIR="/opt/docker/appdata/homeassistant"

echo "Setting up VLAN ${VLAN_ID} sub-interface (${VLAN_IF}) via netplan..."
if [ ! -f "${NETPLAN_FILE}" ]; then
    cat > "${NETPLAN_FILE}" << EOF
network:
  version: 2
  vlans:
    ${VLAN_IF}:
      id: ${VLAN_ID}
      link: ${PARENT_IF}
EOF
    chmod 600 "${NETPLAN_FILE}"
    netplan apply
else
    echo "Netplan VLAN config already exists, skipping."
    chmod 600 "${NETPLAN_FILE}"
fi

echo "Waiting for ${VLAN_IF} to come up..."
for i in $(seq 1 10); do
    if ip link show "${VLAN_IF}" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

echo "Bringing ${VLAN_IF} up..."
ip link set "${VLAN_IF}" up

# --- Recreate macvlan network if it exists with wrong parent ---

NETWORK_RECREATED=0

if docker network inspect "${MACVLAN_NET}" >/dev/null 2>&1; then
    CURRENT_PARENT=$(docker network inspect "${MACVLAN_NET}" -f '{{ index .Options "parent" }}')
    if [ "${CURRENT_PARENT}" != "${VLAN_IF}" ]; then
        echo "Existing '${MACVLAN_NET}' has parent '${CURRENT_PARENT}', expected '${VLAN_IF}'."
        echo "Stopping dependent containers and removing network..."
        if docker ps -a --filter "network=${MACVLAN_NET}" --format '{{.Names}}' | grep -q .; then
            for c in $(docker ps -a --filter "network=${MACVLAN_NET}" --format '{{.Names}}'); do
                echo "Stopping container ${c}..."
                docker stop "${c}" >/dev/null
            done
        fi
        docker network rm "${MACVLAN_NET}"
        NETWORK_RECREATED=1
    fi
fi

echo "Creating macvlan network '${MACVLAN_NET}' on ${VLAN_IF}..."
if ! docker network inspect "${MACVLAN_NET}" >/dev/null 2>&1; then
    docker network create -d macvlan \
        --subnet="${IOT_SUBNET}" \
        --gateway="${IOT_GATEWAY}" \
        -o parent="${VLAN_IF}" \
        "${MACVLAN_NET}"
    NETWORK_RECREATED=1
else
    echo "Network '${MACVLAN_NET}' already exists with correct parent, skipping."
fi

# If the network was recreated, any existing container referencing the old
# network ID is stale and must be removed before compose can recreate it.
if [ "${NETWORK_RECREATED}" -eq 1 ]; then
    if docker ps -a --format '{{.Names}}' | grep -q '^homeassistant$'; then
        echo "Removing stale 'homeassistant' container (network was recreated)..."
        docker rm -f homeassistant >/dev/null
    fi
fi

# --- Shim interface: remove old (wrong parent) version if present ---

if ip link show "${SHIM_IF}" >/dev/null 2>&1; then
    CURRENT_SHIM_PARENT=$(ip link show "${SHIM_IF}" | head -1 | grep -oP "(?<=${SHIM_IF}@).*?(?=:)" || true)
    if [ "${CURRENT_SHIM_PARENT}" != "${VLAN_IF}" ]; then
        echo "Existing shim interface '${SHIM_IF}' has wrong parent ('${CURRENT_SHIM_PARENT}'), removing..."
        systemctl stop "${SHIM_NAME}.service" 2>/dev/null || true
        ip link delete "${SHIM_IF}" 2>/dev/null || true
    fi
fi

echo "Creating systemd unit for persistent shim interface..."
cat > /etc/systemd/system/${SHIM_NAME}.service << EOF
[Unit]
Description=OSAN IoT VLAN macvlan shim interface
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip link add ${SHIM_IF} link ${VLAN_IF} type macvlan mode bridge
ExecStart=/usr/sbin/ip addr add ${SHIM_IP} dev ${SHIM_IF}
ExecStart=/usr/sbin/ip link set ${SHIM_IF} up
ExecStart=/usr/sbin/ip route add ${HA_IP}/32 dev ${SHIM_IF}
ExecStop=/usr/sbin/ip link delete ${SHIM_IF}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${SHIM_NAME}.service

echo "Starting shim interface..."
if ip link show "${SHIM_IF}" >/dev/null 2>&1; then
    echo "Shim interface '${SHIM_IF}' already exists, skipping start."
else
    systemctl start ${SHIM_NAME}.service
fi

# --- Home Assistant container ---

echo "Creating HA app/config directories..."
mkdir -p "${HA_APPDIR}/config"

echo "Writing compose.yaml for Home Assistant..."
cat > "${HA_APPDIR}/compose.yaml" << EOF
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:2026.1.0
    restart: unless-stopped
    environment:
      - TZ=Australia/Brisbane
    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro
    networks:
      iot_macvlan:
        ipv4_address: ${HA_IP}

networks:
  iot_macvlan:
    external: true
EOF

echo "Starting Home Assistant container..."
cd "${HA_APPDIR}" && docker compose up -d

echo ""
echo "Done. Home Assistant should be reachable at http://${HA_IP}:8123"
echo "(allow 1-2 minutes for first boot)"
