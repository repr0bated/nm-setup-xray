#!/bin/bash
set -e

# Check if README includes Xray config section
if ! grep -q "Xray Configuration" README.md; then
  echo "README doesn't have Xray Configuration section, updating..."
  
  # Append Xray config section to README
  cat << 'EOF' >> README.md

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
EOF

  # Stage, commit, and push the changes
  git add README.md
  git commit -m "Add detailed Xray configuration documentation"
  git push
  echo "README updated and changes pushed to GitHub"
else
  echo "README already has Xray Configuration section, no update needed"
fi

# Print first 20 lines of README for verification
echo "First 20 lines of README.md:"
head -20 README.md 