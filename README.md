# Netmaker with Xray Setup

Helper scripts to deploy Netmaker infrastructure with Xray Core in Docker or Podman containers.

## Features

- Compatible with both Docker and Podman
- Automatic setup of Netmaker (server, UI, MQTT broker, proxy)
- Integration with Xray-core on port 443
- Automatic certificate generation
- Persistence support for systemd
- Route synchronization between containers

## Quick Installation

One-line installation command:
```
curl -sfL https://raw.githubusercontent.com/repr0bated/nm-setup-xray/main/scripts/nm-install.sh | sudo bash -s - <DOMAIN>
```

Replace `<DOMAIN>` with your domain name.

## Installation Commands

Setup netmaker server with Xray for your domain:
```
curl -sfL https://raw.githubusercontent.com/repr0bated/nm-setup-xray/main/scripts/nm-install.sh | sudo bash -s - yourdomain.com
```

Join a netmaker network with access TOKEN:
```
curl -sfL https://raw.githubusercontent.com/repr0bated/nm-setup-xray/main/scripts/nm-join.sh | sudo bash -s - <TOKEN>
```

Set up persistence for containers:
```
curl -sfL https://raw.githubusercontent.com/repr0bated/nm-setup-xray/main/scripts/nm-persist.sh | sudo bash -s -
```

Sync routes from containers to host:
```
curl -sfL https://raw.githubusercontent.com/repr0bated/nm-setup-xray/main/scripts/nm-routes.sh | sudo bash -s -
```

## Manual Installation

### Prerequisites

- Linux system with Docker or Podman installed
- Root access (for some operations)
- Basic knowledge of networking

### Installation Steps

1. Clone this repository:
   ```
   git clone https://github.com/repr0bated/nm-setup-xray.git
   cd nm-setup-xray
   ```

2. Run the setup script:
   ```
   ./scripts/nm-setup.sh yourdomain.com
   ```

3. Join a network:
   ```
   ./scripts/nm-join.sh <token>
   ```

4. For persistence across reboots:
   ```
   sudo ./scripts/nm-persist.sh
   ```

## Xray Configuration

Xray is configured to run on port 443 with TLS. All configuration files are stored on the host and mounted into the container, making them easily editable.

### Configuration Files Location

The Xray configuration files are stored in:
- `/var/lib/netmaker/xray/` (if running as root)
- `$HOME/.local/share/netmaker/xray/` (if running as a regular user)

Key files:
- `config.json` - Main Xray configuration file
- `ssl/` - Directory containing SSL certificates
  - `server.key` - Private key
  - `server.crt` - Certificate

### Editing the Xray Configuration

To modify the Xray configuration, edit the `config.json` file in the Xray directory:

```bash
# If running as root
sudo nano /var/lib/netmaker/xray/config.json

# If running as a regular user
nano $HOME/.local/share/netmaker/xray/config.json
```

After editing the configuration, restart the Xray container to apply changes:

```bash
# If using Docker
docker restart netmaker-xray

# If using Podman
podman restart netmaker-xray
```

### Default Xray Configuration

The default Xray configuration uses VLESS protocol with TLS. The client ID is automatically generated during installation.

To add additional clients, edit the `config.json` file and add entries to the `clients` array:

```json
"clients": [
  {
    "id": "existing-uuid",
    "flow": "xtls-rprx-direct"
  },
  {
    "id": "new-uuid-for-another-client",
    "flow": "xtls-rprx-direct"
  }
]
```

You can generate new UUIDs with the `uuidgen` command.

## Script Descriptions

- **nm-install.sh**: All-in-one installation script (for curl installation)
- **nm-prepare.sh**: Prepares the environment, configurations, and pulls images
- **nm-setup.sh**: Deploys the complete Netmaker infrastructure with Xray
- **nm-join.sh**: Helps clients join Netmaker networks
- **nm-persist.sh**: Sets up systemd services for persistence across reboots
- **nm-routes.sh**: Synchronizes routes between containers
- **nm-cleanup.sh**: Removes containers, volumes, and configurations

## Configuration

All configurations are stored in:
- `/var/lib/netmaker` (if running as root)
- `$HOME/.local/share/netmaker` (if running as a regular user)

## License

MIT License
