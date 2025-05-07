# Netmaker with Xray Setup

Helper scripts to deploy Netmaker infrastructure with Xray Core in Docker or Podman containers.

## Features

- Compatible with both Docker and Podman
- Automatic setup of Netmaker (server, UI, MQTT broker, proxy)
- Integration with Xray-core on port 443
- Automatic certificate generation
- Persistence support for systemd
- Route synchronization between containers

## Usage

### Prerequisites

- Linux system with Docker or Podman installed
- Root access (for some operations)
- Basic knowledge of networking

### Installation

1. Clone this repository:
   ```
   git clone https://github.com/yourusername/nm-setup.git
   cd nm-setup
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

## Script Descriptions

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
