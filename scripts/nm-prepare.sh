#!/bin/bash
set -e
RUNTIME=${RUNTIME:-podman}  # Set default runtime to podman if not already set
RUNTIME=${RUNTIME:-podman}  # Set default runtime to podman if not already set

# Arguments
DOMAIN=$1
[ -z "$DOMAIN" ] && echo "Usage: $0 <domain>" && exit 1

# Detect user and set paths accordingly
[ "${EUID:-$(id -u)}" -eq 0 ] \
    && NMDIR=/var/lib/netmaker \
    || NMDIR=$HOME/.local/share/netmaker

echo "Preparing environment for Netmaker and Xray..."

# Create main directories
mkdir -p $NMDIR
mkdir -p $NMDIR/xray
mkdir -p $NMDIR/xray/ssl
mkdir -p $NMDIR/certs

# Detect container runtime
if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    echo "Error: Neither Docker nor Podman is installed."
    exit 1
fi

echo "Using $RUNTIME for preparation..."

# Ensure volumes exist
echo "Creating container volumes..."
$RUNTIME volume create netmaker-data || true
$RUNTIME volume create netmaker-certs || true
$RUNTIME volume create netmaker-mq-data || true
$RUNTIME volume create netmaker-mq-logs || true

# Create xray configuration if it doesn't exist
if [ ! -f $NMDIR/xray/config.json ]; then
    echo "Creating Xray configuration..."
    cat << EOF > $NMDIR/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)",
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
fi

# Generate TLS certificates for Xray if they don't exist
if [ ! -f $NMDIR/xray/ssl/server.key ]; then
    echo "Creating TLS certificates for Xray..."
    openssl req -x509 \
        -newkey rsa:4096 -sha256 \
        -days 3650 -nodes \
        -keyout $NMDIR/xray/ssl/server.key \
        -out $NMDIR/xray/ssl/server.crt \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN"
fi

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
$RUNTIME pull gravitl/netmaker:latest
$RUNTIME pull gravitl/netmaker-ui:latest
$RUNTIME pull eclipse-mosquitto:2.0-openssl
$RUNTIME pull nginx

echo "Preparation complete. All required files and directories are in place."
echo "You can now run nm-setup.sh to start the services." 
# Create config directory for docker-compose.yml
mkdir -p $NMDIR/config

# Create docker-compose.yml in the config directory
echo "Creating docker-compose.yml for podman-compose in $NMDIR/config..."
cat > "$NMDIR/config/docker-compose.yml" << COMPOSEEOF
version: '3'

x-pod: &default-pod-config
  network_mode: "pod"
  pod: netmaker-pod

# When using podman-compose, a pod named "netmaker-pod" will be created
# All services will share the same network namespace
services:
  netmaker-server:
    <<: *default-pod-config
    image: gravitl/netmaker:latest
    container_name: netmaker-server
    restart: unless-stopped
    volumes:
      - netmaker-data:/root/data
      - netmaker-certs:/etc/netmaker/certs
    environment:
      - SERVER_NAME=$DOMAIN
      - MASTER_KEY=TODO_REPLACE_MASTER_KEY
      - SERVER_HOST=api.$DOMAIN
      - DNS_MODE=off
      - CLIENT_MODE=on
      - DATABASE=sqlite
      - DISABLE_REMOTE_IP_CHECK=on
      - API_PORT=8081
      - CORS_ALLOWED_ORIGIN=http://localhost:3000
      - MQ_HOST=127.0.0.1
      - MQ_PORT=1883
      - SERVER_HTTP_HOST=api.$DOMAIN
      - SERVER_HTTP_PORT=443
      - DISPLAY_KEYS=on
      - DEBUG=off
      - HOST_NETWORK=on
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1

  netmaker-ui:
    <<: *default-pod-config
    image: gravitl/netmaker-ui:latest
    container_name: netmaker-ui
    restart: unless-stopped
    environment:
      - BACKEND_URL=https://api.$DOMAIN:8443

  netmaker-mq:
    <<: *default-pod-config
    image: eclipse-mosquitto:2.0-openssl
    container_name: netmaker-mq
    restart: unless-stopped
    volumes:
      - netmaker-mq-data:/mosquitto/data
      - netmaker-mq-logs:/mosquitto/log
      - $NMDIR/mosquitto.conf:/mosquitto/config/mosquitto.conf

  netmaker-proxy:
    <<: *default-pod-config
    image: nginx:latest
    container_name: netmaker-proxy
    restart: unless-stopped
    volumes:
      - $NMDIR/nginx.conf:/etc/nginx/nginx.conf:ro
      - $NMDIR/selfsigned.key:/etc/nginx/ssl/selfsigned.key
      - $NMDIR/selfsigned.crt:/etc/nginx/ssl/selfsigned.crt
    ports:
      - "8443:8443"
      - "8080:8080"

  netmaker-xray:
    <<: *default-pod-config
    image: ghcr.io/xtls/xray-core:sha-59aa5e1-ls
    container_name: netmaker-xray
    restart: unless-stopped
    volumes:
      - $NMDIR/xray/config.json:/etc/xray/config.json
      - $NMDIR/xray/ssl:/etc/xray/ssl
    ports:
      - "443:443"

volumes:
  netmaker-data:
  netmaker-certs:
  netmaker-mq-data:
  netmaker-mq-logs:
COMPOSEEOF

echo "Created docker-compose.yml in $NMDIR/config/"
