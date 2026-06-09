# homelab

Personal homelab configuration, setup scripts, and Docker compose files for Ubuntu Server 24.04.

---

## Repository Structure

```
homelab/
├── setup/
│   └── server-setup.sh     # Post-install setup script for Ubuntu Server 24.04
├── autoinstall/            # Autoinstall USB files (personal copies kept off repo)
│   └── README.md
└── docker/                 # Docker compose files (added as stacks are built out)
```

---

## Getting Started — Fresh Ubuntu Server Install

### Prerequisites

Before running the setup script you need:

- Ubuntu Server 24.04 installed on the target machine
- OpenSSH selected during the Ubuntu install (or installed manually after)
- The machine connected to your network and powered on
- Another machine on the same network to SSH from

---

### Step 1 — Find the server's IP address

On the Ubuntu server console run:

```bash
ip a
```

Look for the `inet` address on your network interface (e.g. `192.168.x.x`).
Alternatively check your router's DHCP client list.

---

### Step 2 — SSH in from another machine

Open a terminal and connect:

```bash
ssh yourusername@x.x.x.x
```

Replace `yourusername` with the username created during Ubuntu install and `x.x.x.x` with the server's IP address from Step 1.

Accept the fingerprint prompt the first time by typing `yes`.

> **Note:** All commands from Step 3 onwards are run on the Ubuntu server inside this SSH session — not on your local machine.

---

### Step 3 — Download the setup script

Once logged in to the server via SSH, download the script:

```bash
curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/server-setup.sh -o server-setup.sh
chmod +x server-setup.sh
```

---

### Step 4 — Run the script

```bash
sudo bash server-setup.sh
```

> **Important:** Do not pipe curl directly into bash (`curl ... | sudo bash`) as this breaks the interactive prompts. Always download first then run.

---

### Step 5 — Answer the interactive menu

The script walks through a series of questions before making any changes. Press **Enter** to accept the default value shown, or type a new value.

| Question | Notes |
|----------|-------|
| Hostname | Defaults to current hostname |
| Username | Typed twice to catch typos. If user exists, skips to next question |
| Password | Only asked if creating a new user. Entered with confirmation, never displayed |
| SSH public key | Optional. Paste your public key for passwordless SSH login. Press Enter to skip |
| GitHub email | Optional — only needed if you want passwordless git access from the server |
| GitHub username | Optional — used in bookmarks and git clone URL |
| Server LAN IP | Auto-detected from network interface. Confirm or change |
| Router IP | Auto-derived from server LAN IP (replaces last octet with .1). Confirm or change |
| Docker connection name | Label used in Homepage to identify this Docker host. Default: `server-docker` |
| Timezone | Detected from system. UTC shown on fresh installs — enter your timezone if needed |
| Docker base directory | Default: `/opt/docker` |
| Appdata subdirectory | Default: `/opt/docker/appdata` |
| Volumes subdirectory | Default: `/opt/docker/volumes` |
| Install Portainer? | Optional Docker management UI. y/N |

A full confirmation summary is shown before anything is changed. Type `y` to proceed or `N` to abort with no changes made.

---

### Step 6 — Add the GitHub SSH key (if applicable)

If you chose to set up GitHub SSH authentication, a public key is displayed at the end of the script. Copy it and add it to GitHub:

1. Go to [https://github.com/settings/ssh/new](https://github.com/settings/ssh/new)
2. Title: your hostname followed by `server` (e.g. `myserver server`)
3. Key type: **Authentication Key**
4. Paste the key and click **Add SSH key**

Test the connection from the server:

```bash
ssh -T git@github.com
```

You should see: `Hi yourusername! You've successfully authenticated...`

Then clone this repo:

```bash
git clone git@github.com:yourusername/homelab.git ~/homelab
```

---

## What the Setup Script Installs

| Component | Purpose | Access |
|-----------|---------|--------|
| Docker CE | Container runtime | CLI |
| Socket Proxy | Protects Docker socket from direct container access | Internal only |
| Dockge | Compose file management UI | `http://<ip>:5001` |
| Homepage | Homelab dashboard with container auto-discovery | `http://<ip>:3000` |
| NGINX Proxy Manager | Reverse proxy with SSL certificate management | `http://<ip>:81` |
| Portainer CE | Docker management UI (optional) | `https://<ip>:9443` |

---

## Docker Directory Structure

```
/opt/docker/
├── .env                            # Environment variables for all stacks (never commit)
├── appdata/
│   ├── socket-proxy/
│   │   └── compose.yaml
│   ├── dockge/
│   │   ├── compose.yaml
│   │   └── stacks/                 # Dockge-managed stacks go here
│   ├── homepage/
│   │   ├── compose.yaml
│   │   └── config/
│   │       ├── bookmarks.yaml
│   │       ├── docker.yaml
│   │       ├── services.yaml
│   │       ├── settings.yaml
│   │       └── widgets.yaml
│   ├── npm/
│   │   └── compose.yaml
│   └── portainer/                  # Only present if Portainer was installed
│       └── compose.yaml
└── volumes/                        # Shared Docker volumes
```

---

## The .env File

The script generates `/opt/docker/.env` automatically with all values filled in from your menu answers. This file is the single source of truth for all stack variables:

```env
PUID=1000
PGID=1000
TZ=Australia/Brisbane
HOSTNAME=myserver
SERVER_LAN_IP=192.168.x.x
ROUTER_IP=192.168.x.1
DOCKER_CONNECTION_NAME=server-docker
DOCKERDIR=/opt/docker
APPDATA=/opt/docker/appdata
VOLUMES=/opt/docker/volumes
...
```

Reference these variables in any compose file:

```yaml
environment:
  - PUID=${PUID}
  - PGID=${PGID}
  - TZ=${TZ}
volumes:
  - ${APPDATA}/myservice:/config
```

> **Never commit `.env` to version control** — it contains your server's IP address and personal details. It is listed in `.gitignore`.

---

## Deploying Additional Stacks

After setup, deploy new containers via CLI:

```bash
# Create a folder for the new service
mkdir -p /opt/docker/appdata/myservice

# Create a compose file
nano /opt/docker/appdata/myservice/compose.yaml

# Start the stack
cd /opt/docker/appdata/myservice
docker compose --env-file /opt/docker/.env up -d
```

---

## NGINX Proxy Manager — First Login

After the script completes, NPM needs to be configured before use:

1. Open `http://<server-ip>:81`
2. Default credentials: `admin@example.com` / `changeme`
3. Change email and password immediately when prompted
4. Set up a wildcard SSL certificate using Cloudflare DNS challenge for your domain
5. Add proxy hosts for each service to get clean URLs without port numbers

---

## Autoinstall (Unattended Ubuntu Install via USB)

The `autoinstall/` folder contains reference information for setting up an unattended Ubuntu Server install via a CIDATA USB stick.

> Personal `user-data` and `meta-data` files are intentionally kept off this repo as they contain hostname, username, and password hash. They live on the CIDATA USB and NAS backup only.
> See `autoinstall/README.md` for full instructions.

---

## Notes

- All Docker data lives under `/opt/docker/`
- Compose files use `compose.yaml` (Compose V2, `.yaml` extension)
- The `.env` file at `/opt/docker/.env` is the single source of truth for all stack variables
- Socket proxy internal subnet `192.168.91.0/24` is Docker-only — not visible on your LAN
- Portainer uses a self-signed certificate — browser security warning on first visit is normal
- Dockge stacks folder: `/opt/docker/appdata/dockge/stacks/`
- Timezone identifiers: [List of tz database time zones](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) — use the TZ Identifier column
