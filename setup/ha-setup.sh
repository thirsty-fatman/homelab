#!/bin/bash
# ha-setup.sh v1.0.3
# Sets up Home Assistant (Docker) on OSAN via macvlan on IoT VLAN (192.168.8.x)
# Independent of server-setup.sh / cloudflare-setup.sh / npm-setup.sh
# Local access only for now: http://192.168.8.2:8123

set -e

# --- Network setup: macvlan for IoT VLAN (192.168.8.x) ---

IOT_SUBNET="192.168.8.0/24"
IOT_GATEWAY="192.168.8.1"
PARENT_IF="eno1"
MACVLAN_NET="iot_macvlan"
SHIM_IF="iot-shim"
SHIM_IP="192.168.8.3/32"
SHIM_NAME="osan-shimnet"

HA_IP="192.168.8.2"

echo "Creating macvlan network '${MACVLAN_NET}' on ${PARENT_IF}..."
if ! docker network inspect "${MACVLAN_NET}" >/dev/null 2>&1; then
    docker network create -d macvlan \
        --subnet="${IOT_SUBNET}" \
        --gateway="${IOT_GATEWAY}" \
        -o parent="${PARENT_IF}" \
        "${MACVLAN_NET}"
else
    echo "Network '${MACVLAN_NET}' already exists, skipping."
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
ExecStart=/usr/sbin/ip link add ${SHIM_IF} link ${PARENT_IF} type macvlan mode bridge
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

HA_APPDIR="/opt/docker/appdata/homeassistant"

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
