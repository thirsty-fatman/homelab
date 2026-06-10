# homelab

Personal homelab configuration, setup scripts, and Docker compose files for Ubuntu Server 24.04.

---

## Repository Structure

```
homelab/
├── setup/
│   ├── server-setup.sh         # Post-install setup script for Ubuntu Server 24.04
│   ├── cloudflare-setup.sh     # Cloudflare DNS A record configuration
│   └── npm-setup.sh            # NGINX Proxy Manager SSL and proxy host setup
├── experimental/
│   └── autoinstall/            # Unattended Ubuntu install — work in progress
│       └── README.md
└── docker/                     # Docker compose files (added as stacks are built out)
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

> **If you get a `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` error** (e.g. after a reinstall):
> ```bash
> ssh-keygen -R x.x.x.x
> ```
> Then SSH in again as normal.

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
| Timezone | Detected from system. Link provided to look up valid timezone identifiers |
| Docker base directory | Default: `/opt/docker` |
| Appdata subdirectory | Default: `/opt/docker/appdata` |
| Volumes subdirectory | Default: `/opt/docker/volumes` |
| Install Portainer? | Optional Docker management UI. y/N |

A full confirmation summary is shown before anything is changed. Type `y` to proceed or `N` to abort with no changes made.

---

### Step 6 — Post-setup configuration menu

After all stacks are deployed, the script offers optional additional configuration:

| Option | Action |
|--------|--------|
| 1 | Run Cloudflare DNS setup then NPM setup (recommended) |
| 2 | Run Cloudflare DNS setup only — will ask about NPM after |
| 3 | Run NPM setup only — validates Cloudflare has been run first |
| 4 | Skip — run scripts manually later (commands shown in summary) |

---

### Step 7 — Add the GitHub SSH key (if applicable)

If you chose to set up GitHub SSH authentication, a public key is displayed at the end of the script. Copy it and add it to GitHub:

1. Go to [https://github.com/settings/ssh/new](https://github.com/settings/ssh/new)
2. Title: your hostname followed by `server` (e.g. `myserver server`)
3. Key type: **Authentication Key**
4. Paste the key and click **Add SSH key**

Test the connection from the server:

```bash
ssh -T git@github.com
```

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

## Additional Setup Scripts

### cloudflare-setup.sh

Configures Cloudflare DNS A records for all homelab services. Safe to re-run — creates, updates, or skips records as needed.

**What it does:**
- Validates your Cloudflare API token
- Looks up the Zone ID for your domain automatically
- Creates or updates DNS A records for each service pointing to your server IP
- Saves token, domain, and Zone ID to `/opt/docker/.env` for use by other scripts

**Usage:**
```bash
curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/cloudflare-setup.sh -o cloudflare-setup.sh
sudo bash cloudflare-setup.sh
```

**Requirements:**
- A Cloudflare account with your domain added
- A Cloudflare API token with Edit zone DNS permissions scoped to your domain
- Generate at: https://dash.cloudflare.com/profile/api-tokens

---

### npm-setup.sh

Configures NGINX Proxy Manager via its REST API. Safe to re-run — creates, updates, or skips as needed.

**What it does:**
- Reads domain, server IP, and Cloudflare token from `/opt/docker/.env` (prompts if missing)
- Waits for NPM to be healthy before proceeding
- Changes default admin credentials to your supplied email and password
- Creates a wildcard SSL certificate via Cloudflare DNS challenge
- Creates proxy hosts for all core services with SSL and HTTP/2
- Updates Homepage `services.yaml` with `https://service.domain` URLs (preserves manual overrides)
- Restarts Homepage to apply URL changes

**Usage:**
```bash
curl -fsSL https://raw.githubusercontent.com/thirsty-fatman/homelab/main/setup/npm-setup.sh -o npm-setup.sh
sudo bash npm-setup.sh
```

**Requirements:**
- NPM container must be running
- `cloudflare-setup.sh` must have been run first (or token/domain will be prompted)
- Your domain's DNS must be managed by Cloudflare

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
CLOUDFLARE_TOKEN=yourtoken
DOMAIN=yourdomain.com
ZONE_ID=yourzoneid
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

> **Never commit `.env` to version control** — it contains your server's IP address, domain, and Cloudflare token. It is listed in `.gitignore`.

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

## Experimental

The `experimental/` folder contains work-in-progress features that are not part of the current build. See individual README files within for details and contribution notes.

---

## Notes

- All Docker data lives under `/opt/docker/`
- Compose files use `compose.yaml` (Compose V2, `.yaml` extension)
- The `.env` file at `/opt/docker/.env` is the single source of truth for all stack variables
- Socket proxy internal subnet `192.168.91.0/24` is Docker-only — not visible on your LAN
- Portainer uses a self-signed certificate — browser security warning on first visit is normal
- Dockge stacks folder: `/opt/docker/appdata/dockge/stacks/`
- Timezone identifiers: [List of tz database time zones](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) — use the TZ Identifier column
