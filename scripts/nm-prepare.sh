#!/bin/bash
set -e
RUNTIME=${RUNTIME:-podman}  # Set default runtime to podman if not already set

# This script prepares the host environment for the Docker Compose setup.
# It creates configuration files and an .env file.

# Configuration base directory relative to where docker-compose.yml is expected to be.
# Assumes this script is run from the root of the project, same as docker-compose.yml
CONFIG_DIR="./config"
ENV_FILE=".env"

# --- Gather Domain (from $1 or prompt) ---
DOMAIN_ARG=$1
if [ -n "$DOMAIN_ARG" ]; then
    DOMAIN="$DOMAIN_ARG"
    echo "Using DOMAIN from argument: $DOMAIN"
else
    read -p "Enter the domain for Netmaker (e.g., yourdomain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo "Error: Domain is required." >&2
        exit 1
    fi
fi

# --- Gather Master Key (from $2 or prompt/auto-generate) ---
MASTER_KEY_ARG=$2
if [ -n "$MASTER_KEY_ARG" ]; then
    if [ "${#MASTER_KEY_ARG}" -lt 16 ]; then
        echo "Error: MASTER_KEY provided as argument must be at least 16 characters long." >&2
        exit 1
    fi
    MASTER_KEY="$MASTER_KEY_ARG"
    echo "Using MASTER_KEY from argument."
else
    echo "MASTER_KEY not provided as an argument."
    read -p "Enter a new MASTER_KEY (at least 16 chars, leave blank to auto-generate): " user_master_key
    if [ -n "$user_master_key" ]; then
        if [ "${#user_master_key}" -lt 16 ]; then
            echo "Error: MASTER_KEY must be at least 16 characters long." >&2
            exit 1
        fi
        MASTER_KEY="$user_master_key"
        echo "Using user-provided MASTER_KEY."
    else
        MASTER_KEY=$(openssl rand -hex 32)
        echo "Auto-generated a new MASTER_KEY: $MASTER_KEY"
    fi
    echo "----------------------------------------------------------------------"
    echo "IMPORTANT: Your Netmaker MASTER_KEY is: $MASTER_KEY"
    echo "Please SAVE THIS KEY in a secure location."
    echo "----------------------------------------------------------------------"
fi

# --- Create .env file ---
echo "Creating .env file..."
cat > "$ENV_FILE" << EOF
# Environment variables for Netmaker Compose setup
DOMAIN=$DOMAIN
MASTER_KEY=$MASTER_KEY

# Default ports (can be overridden here or by docker-compose --env-file)
SERVER_PORT_INTERNAL=8081
SERVER_HTTPS_PORT=8443
DASHBOARD_HTTPS_PORT=8080
XRAY_PORT=443

# Default versions (can be overridden)
NETMAKER_VERSION=latest
MOSQUITTO_VERSION=2.0-openssl
NETMAKER_UI_VERSION=latest
NGINX_VERSION=latest
XRAY_VERSION=sha-59aa5e1-ls
EOF
echo ".env file created. You can customize ports/versions in this file before running 'docker-compose up'."

# --- Create configuration directories ---
echo "Creating host directories for configuration files under $CONFIG_DIR..."
mkdir -p "$CONFIG_DIR/xray/ssl"
mkdir -p "$CONFIG_DIR/ssl" # For Nginx certs

# --- Generate Xray configuration if it doesn't exist ---
XRAY_CONFIG_FILE_TOML="$CONFIG_DIR/xray/config.toml"
# Also remove old json if present to avoid conflict
rm -f "$CONFIG_DIR/xray/config.json"

if [ ! -f "$XRAY_CONFIG_FILE_TOML" ]; then
    echo "Creating Xray TOML configuration: $XRAY_CONFIG_FILE_TOML..."
    XRAY_CLIENT_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    # Note: XRAY_PORT from .env is for docker-compose port mapping.
    # Xray itself reads the port from its config or defaults to what its VLESS settings imply (usually 443 for TLS).
    # Here, we explicitly set the listen port in the TOML to 443 for clarity.
    cat << EOF > "$XRAY_CONFIG_FILE_TOML"
# Xray main configuration file (TOML format)

[log]
loglevel = "warning"

[[inbounds]]
port = 443 # Xray service listening port inside the container
protocol = "vless"
[inbounds.settings]
decryption = "none"
  [[inbounds.settings.clients]]
  id = "$XRAY_CLIENT_ID"
  flow = "xtls-rprx-direct"
  # email = "user@example.com" # Optional client identifier

[[inbounds.streamSettings]]
network = "tcp"
security = "tls"
  [inbounds.streamSettings.tlsSettings]
  alpn = ["http/1.1"]
  [[inbounds.streamSettings.tlsSettings.certificates]]
  certificateFile = "/etc/xray/ssl/server.crt"
  keyFile = "/etc/xray/ssl/server.key"

# Example fallback if needed (e.g., to a local web server if TLS handshake fails for VLESS)
# [[inbounds.settings.fallbacks]]
# alpn = "h2" # or mKCP or ...
# dest = 8080 # Redirect to this port on localhost

[[outbounds]]
protocol = "freedom"
# tag = "direct" # Optional tag

# Other common sections like routing, policy, dns, transport can be added here as needed.
EOF
    echo "Default Xray client ID: $XRAY_CLIENT_ID"
else
    echo "Xray TOML configuration $XRAY_CONFIG_FILE_TOML already exists. Skipping creation."
fi

# --- Generate TLS certificates for Xray if they don't exist ---
XRAY_KEY_FILE="$CONFIG_DIR/xray/ssl/server.key"
XRAY_CERT_FILE="$CONFIG_DIR/xray/ssl/server.crt"
if [ ! -f "$XRAY_KEY_FILE" ] || [ ! -f "$XRAY_CERT_FILE" ]; then
    echo "Creating TLS certificates for Xray in $CONFIG_DIR/xray/ssl/..."
    openssl req -x509 \
        -newkey rsa:4096 -sha256 \
        -days 3650 -nodes \
        -keyout "$XRAY_KEY_FILE" \
        -out "$XRAY_CERT_FILE" \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN"
else
    echo "Xray TLS certificates in $CONFIG_DIR/xray/ssl/ already exist. Skipping creation."
fi

# --- Create Mosquitto configuration if it doesn't exist ---
MOSQUITTO_CONFIG_FILE="$CONFIG_DIR/mosquitto.conf"
if [ ! -f "$MOSQUITTO_CONFIG_FILE" ]; then
    echo "Creating Mosquitto configuration: $MOSQUITTO_CONFIG_FILE..."
    cat << EOF > "$MOSQUITTO_CONFIG_FILE"
# Create mosquitto configuration if it doesn't exist
if [ ! -f $NMDIR/mosquitto.conf ]; then
    echo "Creating Mosquitto configuration..."
    cat << EOF > $NMDIR/mosquitto.conf
per_listener_settings true

listener 8883
allow_anonymous false
require_certificate true
use_identity_as_username true
cafile /mosquitto/certs/root.pem
certfile /mosquitto/certs/server.pem
keyfile /mosquitto/certs/server.key

listener 1883
allow_anonymous true
EOF
fi

# Create nginx configuration if it doesn't exist
if [ ! -f $NMDIR/nginx.conf ]; then
    echo "Creating Nginx configuration..."
    cat << EOF > $NMDIR/nginx.conf
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log    /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    server {
        listen       8443 ssl;
        server_name api.$DOMAIN;

        #access_log  /var/log/nginx/host.access.log  main;

        ssl_certificate /etc/nginx/ssl/selfsigned.crt;
        ssl_certificate_key /etc/nginx/ssl/selfsigned.key;

        location / {
            proxy_pass   http://127.0.0.1:8081;
        }

        #error_page  404              /404.html;

        # Redirect server error pages to the static page /50x.html
        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/share/nginx/html;
        }
    }

    server {
        listen       8080 ssl;
        server_name dashboard.$DOMAIN;

        #access_log  /var/log/nginx/host.access.log  main;

        ssl_certificate /etc/nginx/ssl/selfsigned.crt;
        ssl_certificate_key /etc/nginx/ssl/selfsigned.key;

        location / {
            proxy_pass   http://127.0.0.1:80;
        }

        #error_page  404              /404.html;

        # Redirect server error pages to the static page /50x.html
        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/share/nginx/html;
        }
    }
}
EOF
fi

# Generate TLS certificates for Nginx if they don't exist
if [ ! -f $NMDIR/selfsigned.key ]; then
    echo "Creating TLS certificates for Nginx..."
    openssl req -x509 \
        -newkey rsa:4096 -sha256 \
        -days 3650 -nodes \
        -keyout $NMDIR/selfsigned.key \
        -out $NMDIR/selfsigned.crt \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN"
fi

# Pull necessary images
echo "Pulling required container images..."
$RUNTIME pull ghcr.io/xtls/xray-core:sha-59aa5e1-ls
$RUNTIME pull docker.io/gravitl/netmaker:latest
$RUNTIME pull docker.io/gravitl/netmaker-ui:latest
$RUNTIME pull docker.io/eclipse-mosquitto:2.0-openssl
$RUNTIME pull docker.io/nginx:latest

echo "Preparation complete. Host directories and configuration files are ready under $CONFIG_DIR."
echo "The .env file has been created/updated with your domain and master key."
echo "You can now run 'docker-compose up -d' or 'podman-compose up -d'." 