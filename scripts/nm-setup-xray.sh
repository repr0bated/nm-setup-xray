#!/bin/bash
set -e

# Arguments
DOMAIN=$1
[ -z "$DOMAIN" ] && echo "Usage: $0 <domain>" && exit 1

# Directory for configuration and data
[ "${EUID:-$(id -u)}" -eq 0 ] \
    && NMDIR=/var/lib/netmaker \
    || NMDIR=$HOME/.local/share/netmaker

# Create state directory if not exists
[ ! -d $NMDIR/xray ] && mkdir -p $NMDIR/xray

# Xray configuration in TOML format
[ ! -f $NMDIR/xray/config.toml ] && cat << EOF > $NMDIR/xray/config.toml
# Xray Configuration in TOML format

# Log settings
[log]
loglevel = "warning"

# Inbound configurations
[[inbounds]]
port = 443
protocol = "vless"
  [inbounds.settings]
  decryption = "none"
    [[inbounds.settings.clients]]
    id = "$(uuidgen)"
    flow = "xtls-rprx-direct"
  [inbounds.streamSettings]
  network = "tcp"
  security = "tls"
    [inbounds.streamSettings.tlsSettings]
    alpn = ["http/1.1"]
      [[inbounds.streamSettings.tlsSettings.certificates]]
      certificateFile = "/etc/xray/ssl/server.crt"
      keyFile = "/etc/xray/ssl/server.key"

# Outbound configurations
[[outbounds]]
protocol = "freedom"
EOF

# Generate TLS certificates for Xray
if [ ! -f $NMDIR/xray/server.key ]; then
    echo "Creating xray TLS certificates..."
    mkdir -p $NMDIR/xray/ssl
    openssl req -x509 \
        -newkey rsa:4096 -sha256 \
        -days 3650 -nodes \
        -keyout $NMDIR/xray/ssl/server.key \
        -out $NMDIR/xray/ssl/server.crt \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN"
fi

# Detect container runtime
if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    echo "Error: Neither Docker nor Podman is installed."
    exit 1
fi

echo "Using $RUNTIME to set up xray-core..."

# Pull the xray image
$RUNTIME pull ghcr.io/xtls/xray-core:sha-59aa5e1-ls

# Check if we're using podman with the netmaker pod
if [ "$RUNTIME" = "podman" ] && podman pod exists netmaker; then
    echo "Adding xray-core to the netmaker pod..."
    podman run -d --pod netmaker --name netmaker-xray \
        -v $NMDIR/xray/config.toml:/etc/xray/config.toml \
        -v $NMDIR/xray/ssl:/etc/xray/ssl \
        -p 443:443 \
        --restart unless-stopped \
        ghcr.io/xtls/xray-core:sha-59aa5e1-ls
else
    # For Docker or standalone Podman
    echo "Creating standalone xray-core container..."
    $RUNTIME run -d --name netmaker-xray \
        -v $NMDIR/xray/config.toml:/etc/xray/config.toml \
        -v $NMDIR/xray/ssl:/etc/xray/ssl \
        -p 443:443 \
        --restart unless-stopped \
        ghcr.io/xtls/xray-core:sha-59aa5e1-ls
fi

echo "Xray has been set up and is running on port 443."
echo "Configuration file: $NMDIR/xray/config.toml"
echo "SSL certificates: $NMDIR/xray/ssl/" 