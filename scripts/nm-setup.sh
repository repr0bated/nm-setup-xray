#!/bin/bash
set -e

# Arguments
DOMAIN=$1
[ -z "$DOMAIN" ] && echo "Usage: $0 <domain>" && exit 1

SERVER_PORT=${2:-8081}
BROKER_PORT=${3:-8883}
DASHBOARD_PORT=${4:-8080}

# Run preparation script first to ensure all files are in place
echo "Running preparation script..."
./scripts/nm-prepare.sh $DOMAIN

# Handle Master Key
MASTER_KEY_PLACEHOLDER="TODO_REPLACE_MASTER_KEY"
CURRENT_MASTER_KEY="${NM_MASTER_KEY:-$MASTER_KEY_PLACEHOLDER}" # Read from env var NM_MASTER_KEY, fallback to placeholder

if [ "$CURRENT_MASTER_KEY" = "$MASTER_KEY_PLACEHOLDER" ]; then
  echo "WARNING: The default Netmaker MASTER_KEY is insecure or not set."
  echo "You can set it permanently by exporting NM_MASTER_KEY in your shell environment."
  read -p "Enter a new MASTER_KEY (at least 16 chars, leave blank to auto-generate): " user_master_key
  if [ -n "$user_master_key" ]; then
    if [ "${#user_master_key}" -lt 16 ]; then
      echo "Error: MASTER_KEY must be at least 16 characters long." 
      exit 1
    fi
    MASTER_KEY="$user_master_key"
    echo "Using user-provided MASTER_KEY."
  else
    MASTER_KEY=$(openssl rand -hex 32) # Generate a 64-character hex key
    echo "Auto-generated a new MASTER_KEY."
  fi
  echo "----------------------------------------------------------------------"
  echo "IMPORTANT: Your Netmaker MASTER_KEY is: $MASTER_KEY"
  echo "Please SAVE THIS KEY in a secure location. It is crucial for server"
  echo "recovery or if you need to redeploy your Netmaker server."
  echo "----------------------------------------------------------------------"
else
  MASTER_KEY="$CURRENT_MASTER_KEY"
  echo "Using MASTER_KEY from environment variable NM_MASTER_KEY."
fi

# Directory containing volume data
[ "${EUID:-$(id -u)}" -eq 0 ] \
    && NMDIR=/var/lib/netmaker \
    || NMDIR=$HOME/.local/share/netmaker

# Create state directory if not exists
[ ! -d $NMDIR ] && mkdir -p $NMDIR

# Detect container runtime
if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    echo "Error: Neither Docker nor Podman is installed."
    exit 1
fi

echo "Using $RUNTIME for deployment..."

# Create empty pod if using podman
if [ "$RUNTIME" = "podman" ]; then
    echo "Creating netmaker pod ..."
    podman pod create -n netmaker \
        -p $SERVER_PORT:8443 \
        -p $BROKER_PORT:8883 \
        -p $DASHBOARD_PORT:8080 \
        -p 443:443 \
        -p 51821-51830:51821-51830/udp
fi

#
# Server
#

# Launch server
echo "Creating netmaker-server container ..."
if [ "$RUNTIME" = "podman" ]; then
    podman run -d --pod netmaker --name netmaker-server \
        -v netmaker-data:/root/data \
        -v netmaker-certs:/etc/netmaker \
        -e SERVER_NAME=broker.$DOMAIN \
        -e SERVER_API_CONN_STRING=api.$DOMAIN:$SERVER_PORT \
        -e MASTER_KEY=$MASTER_KEY \
        -e DATABASE=sqlite \
        -e NODE_ID=netmaker-server \
        -e MQ_HOST=localhost \
        -e MQ_PORT=$BROKER_PORT \
        -e TELEMETRY=off \
        -e VERBOSITY="3" \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        --cap-add SYS_MODULE \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv6.conf.all.forwarding=1 \
        --restart unless-stopped \
        gravitl/netmaker:latest
else
    # Docker version
    $RUNTIME run -d --name netmaker-server \
        -p $SERVER_PORT:8443 \
        -v netmaker-data:/root/data \
        -v netmaker-certs:/etc/netmaker \
        -e SERVER_NAME=broker.$DOMAIN \
        -e SERVER_API_CONN_STRING=api.$DOMAIN:$SERVER_PORT \
        -e MASTER_KEY=$MASTER_KEY \
        -e DATABASE=sqlite \
        -e NODE_ID=netmaker-server \
        -e MQ_HOST=localhost \
        -e MQ_PORT=$BROKER_PORT \
        -e TELEMETRY=off \
        -e VERBOSITY="3" \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        --cap-add SYS_MODULE \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --sysctl net.ipv6.conf.all.forwarding=1 \
        --restart unless-stopped \
        --network host \
        gravitl/netmaker:latest
fi

#
# Broker
#

# Prepare broker configuration
[ ! -f $NMDIR/mosquitto.conf ] && cat << EOF > $NMDIR/mosquitto.conf
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

# Launch broker
echo "Creating netmaker-mq container ..."
if [ "$RUNTIME" = "podman" ]; then
    podman run -d --pod netmaker --name netmaker-mq \
        -v $NMDIR/mosquitto.conf:/mosquitto/config/mosquitto.conf \
        -v netmaker-mq-data:/mosquitto/data \
        -v netmaker-mq-logs:/mosquitto/log \
        -v netmaker-certs:/mosquitto/certs \
        --restart unless-stopped \
        eclipse-mosquitto:2.0-openssl
else
    # Docker version
    $RUNTIME run -d --name netmaker-mq \
        -p $BROKER_PORT:8883 \
        -v $NMDIR/mosquitto.conf:/mosquitto/config/mosquitto.conf \
        -v netmaker-mq-data:/mosquitto/data \
        -v netmaker-mq-logs:/mosquitto/log \
        -v netmaker-certs:/mosquitto/certs \
        --restart unless-stopped \
        eclipse-mosquitto:2.0-openssl
fi

#
# UI
#

# Launch ui
echo "Creating netmaker-ui container ..."
if [ "$RUNTIME" = "podman" ]; then
    podman run -d --pod netmaker --name netmaker-ui \
        -e BACKEND_URL=https://api.$DOMAIN:$SERVER_PORT \
        --restart unless-stopped \
        gravitl/netmaker-ui:latest
else
    # Docker version
    $RUNTIME run -d --name netmaker-ui \
        -p $DASHBOARD_PORT:80 \
        -e BACKEND_URL=https://api.$DOMAIN:$SERVER_PORT \
        --restart unless-stopped \
        gravitl/netmaker-ui:latest
fi

#
# Reverse Proxy
#

# Prepare reverse proxy certificates
if [ ! -f $NMDIR/selfsigned.key ]; then
    echo "Creating netmaker-proxy tls certificates ..."
    openssl req -x509 \
        -newkey rsa:4096 -sha256 \
        -days 3650 -nodes \
        -keyout $NMDIR/selfsigned.key \
        -out $NMDIR/selfsigned.crt \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN"
fi

# Prepare reverse proxy configuration
[ ! -f $NMDIR/nginx.conf ] && cat << EOF > $NMDIR/nginx.conf
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

# Launch reverse proxy
echo "Creating netmaker-proxy container ..."
if [ "$RUNTIME" = "podman" ]; then
    podman run -d --pod netmaker --name netmaker-proxy \
        -v $NMDIR/nginx.conf:/etc/nginx/nginx.conf:ro \
        -v $NMDIR/selfsigned.key:/etc/nginx/ssl/selfsigned.key \
        -v $NMDIR/selfsigned.crt:/etc/nginx/ssl/selfsigned.crt \
        --restart unless-stopped \
        nginx
else
    # Docker version
    $RUNTIME run -d --name netmaker-proxy \
        -p 8443:8443 \
        -p 8080:8080 \
        -v $NMDIR/nginx.conf:/etc/nginx/nginx.conf:ro \
        -v $NMDIR/selfsigned.key:/etc/nginx/ssl/selfsigned.key \
        -v $NMDIR/selfsigned.crt:/etc/nginx/ssl/selfsigned.crt \
        --restart unless-stopped \
        --network host \
        nginx
fi

#
# Xray
#

# Launch xray
echo "Creating netmaker-xray container ..."
if [ "$RUNTIME" = "podman" ]; then
    # Using podman with netmaker pod
    podman run -d --pod netmaker --name netmaker-xray \
        -v $NMDIR/xray/config.json:/etc/xray/config.json \
        -v $NMDIR/xray/ssl:/etc/xray/ssl \
        --restart unless-stopped \
        ghcr.io/xtls/xray-core:sha-59aa5e1-ls
else
    # Docker version
    $RUNTIME run -d --name netmaker-xray \
        -p 443:443 \
        -v $NMDIR/xray/config.json:/etc/xray/config.json \
        -v $NMDIR/xray/ssl:/etc/xray/ssl \
        --restart unless-stopped \
        ghcr.io/xtls/xray-core:sha-59aa5e1-ls
fi

echo "Setup complete! Netmaker is running with Xray on port 443."
