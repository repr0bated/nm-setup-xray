#!/bin/bash
set -e

# This script prepares the host environment for the Docker Compose setup.
# It creates configuration files and an .env file.

# Configuration base directory relative to where docker-compose.yml is expected to be.
# Assumes this script is run from the root of the project, same as docker-compose.yml
CONFIG_DIR="./config"
ENV_FILE=".env"

# --- Gather Domain --- 
if [ -n "$NM_DOMAIN" ]; then
    DOMAIN="$NM_DOMAIN"
    echo "Using DOMAIN from environment variable NM_DOMAIN: $DOMAIN"
else
    read -p "Enter the domain for Netmaker (e.g., yourdomain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo "Error: Domain is required." >&2
        exit 1
    fi
fi

# --- Gather Master Key --- 
MASTER_KEY_PLACEHOLDER="TODO_REPLACE_MASTER_KEY"
if [ -n "$NM_MASTER_KEY" ] && [ "$NM_MASTER_KEY" != "$MASTER_KEY_PLACEHOLDER" ]; then
    MASTER_KEY="$NM_MASTER_KEY"
    echo "Using MASTER_KEY from environment variable NM_MASTER_KEY."
else
    echo "Netmaker MASTER_KEY is not set via NM_MASTER_KEY or is the default placeholder."
    read -p "Enter a new MASTER_KEY (at least 16 chars, leave blank to auto-generate): " user_master_key
    if [ -n "$user_master_key" ]; then
        if [ "${#user_master_key}" -lt 16 ]; then
            echo "Error: MASTER_KEY must be at least 16 characters long." >&2
            exit 1
        fi
        MASTER_KEY="$user_master_key"
        echo "Using user-provided MASTER_KEY."
    else
        MASTER_KEY=$(openssl rand -hex 32) # Generate a 64-character hex key
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
XRAY_CONFIG_FILE="$CONFIG_DIR/xray/config.json"
if [ ! -f "$XRAY_CONFIG_FILE" ]; then
    echo "Creating Xray configuration: $XRAY_CONFIG_FILE..."
    XRAY_CLIENT_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    cat << EOF > "$XRAY_CONFIG_FILE"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${XRAY_PORT:-443}, # Will be substituted by Xray itself from its env or default 443
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_CLIENT_ID",
            "flow": "xtls-rprx-direct"
          }
        ],
        "decryption": "none",
        "fallbacks": []
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "/etc/xray/ssl/server.crt",
              "keyFile": "/etc/xray/ssl/server.key"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
    echo "Default Xray client ID: $XRAY_CLIENT_ID"
else
    echo "Xray configuration $XRAY_CONFIG_FILE already exists. Skipping creation."
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

echo "Preparation complete. All required files and directories are in place."
echo "You can now run nm-setup.sh to start the services." 