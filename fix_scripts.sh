#!/bin/bash

# Fix the syntax error in nm-prepare.sh
sed -i '309s/echo "You can now run '\''docker-compose up -d'\''." fi/echo "You can now run '\''docker-compose up -d'\''."/' /home/jeremy/nm-setup/scripts/nm-prepare.sh
echo "fi" >> /home/jeremy/nm-setup/scripts/nm-prepare.sh

# Create podman-compose.yml in the current directory
cat > /home/jeremy/nm-setup/podman-compose.yml << 'EOF'
version: '3.8'

# Special podman-compose compatible configuration with pod-level networking
services:
  netmaker-pod:
    image: k8s.gcr.io/pause:3.5
    container_name: netmaker-pod
    hostname: netmaker-pod
    restart: unless-stopped
    ports:
      # Define all ports at the pod level
      - "${WIREGUARD_PORT_START:-51821}-${WIREGUARD_PORT_END:-51830}:${WIREGUARD_PORT_START:-51821}-${WIREGUARD_PORT_END:-51830}/udp"
      - "${SERVER_HTTPS_PORT:-8443}:${SERVER_HTTPS_PORT:-8443}"
      - "${DASHBOARD_HTTPS_PORT:-8080}:${DASHBOARD_HTTPS_PORT:-8080}"
      - "${XRAY_PORT:-443}:${XRAY_PORT:-443}"
    # Pod-level sysctls
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1

  netmaker-server:
    image: docker.io/gravitl/netmaker:${NETMAKER_VERSION:-latest}
    container_name: netmaker-server
    hostname: netmaker-server
    restart: unless-stopped
    environment:
      SERVER_NAME: broker.${DOMAIN}
      SERVER_API_CONN_STRING: api.${DOMAIN}:${SERVER_PORT_INTERNAL}
      MASTER_KEY: ${MASTER_KEY}
      DATABASE: sqlite
      NODE_ID: netmaker-server
      MQ_HOST: localhost # Use localhost since we're in the same pod
      MQ_PORT: 1883 # Internal MQTT port
      TELEMETRY: "off"
      VERBOSITY: "3"
      SERVER_PORT_INTERNAL: ${SERVER_PORT_INTERNAL:-8081}
    volumes:
      - netmaker_data:/root/data
      - netmaker_certs:/etc/netmaker
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_MODULE
    # Use pod instead of bridge
    pod: netmaker-pod

  netmaker-mq:
    image: docker.io/eclipse-mosquitto:${MOSQUITTO_VERSION:-2.0-openssl}
    container_name: netmaker-mq
    hostname: netmaker-mq
    restart: unless-stopped
    volumes:
      - ./config/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - netmaker_mq_data:/mosquitto/data
      - netmaker_mq_logs:/mosquitto/log
      - netmaker_certs:/mosquitto/certs
    pod: netmaker-pod

  netmaker-ui:
    image: docker.io/gravitl/netmaker-ui:${NETMAKER_UI_VERSION:-latest}
    container_name: netmaker-ui
    hostname: netmaker-ui
    restart: unless-stopped
    environment:
      BACKEND_URL: https://api.${DOMAIN}:${SERVER_HTTPS_PORT}
    pod: netmaker-pod
    depends_on:
      - netmaker-proxy

  netmaker-proxy:
    image: docker.io/nginx:${NGINX_VERSION:-latest}
    container_name: netmaker-proxy
    hostname: netmaker-proxy
    restart: unless-stopped
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/ssl/selfsigned.key:/etc/nginx/ssl/selfsigned.key:ro
      - ./config/ssl/selfsigned.crt:/etc/nginx/ssl/selfsigned.crt:ro
    pod: netmaker-pod
    depends_on:
      - netmaker-server
      - netmaker-ui

  netmaker-xray:
    image: ghcr.io/xtls/xray-core:${XRAY_VERSION:-sha-59aa5e1-ls}
    container_name: netmaker-xray
    hostname: netmaker-xray
    restart: unless-stopped
    volumes:
      - ./config/xray/config.toml:/etc/xray/config.toml:ro
      - ./config/xray/ssl:/etc/xray/ssl:ro
    pod: netmaker-pod

volumes:
  netmaker_data:
  netmaker_certs:
  netmaker_mq_data:
  netmaker_mq_logs:
EOF

# Modify nm-setup.sh to prefer podman-compose and use the pod networking file
sed -i 's/if command -v docker-compose >/if command -v podman-compose >/g' /home/jeremy/nm-setup/scripts/nm-setup.sh
sed -i 's/    COMPOSE_CMD="docker-compose"/    COMPOSE_CMD="podman-compose"/g' /home/jeremy/nm-setup/scripts/nm-setup.sh
sed -i 's/elif command -v podman-compose >/elif command -v docker-compose >/g' /home/jeremy/nm-setup/scripts/nm-setup.sh
sed -i 's/    COMPOSE_CMD="podman-compose"/    COMPOSE_CMD="docker-compose"/g' /home/jeremy/nm-setup/scripts/nm-setup.sh

# Add code to check for podman-compose.yml
sed -i '/COMPOSE_CMD=""/a COMPOSE_FILE="docker-compose.yml"' /home/jeremy/nm-setup/scripts/nm-setup.sh
sed -i '/COMPOSE_CMD="podman-compose"/a \ \ \ \ # Use special podman-compose.yml file if it exists\n    if [ -f "$REPO_ROOT/podman-compose.yml" ]; then\n        COMPOSE_FILE="podman-compose.yml"\n    fi' /home/jeremy/nm-setup/scripts/nm-setup.sh

# Update the compose command to use the selected file
sed -i 's/echo "Using $COMPOSE_CMD for deployment..."/echo "Using $COMPOSE_CMD with $COMPOSE_FILE for deployment..."/' /home/jeremy/nm-setup/scripts/nm-setup.sh
sed -i 's/$COMPOSE_CMD -f docker-compose.yml up -d/$COMPOSE_CMD -f $COMPOSE_FILE up -d/' /home/jeremy/nm-setup/scripts/nm-setup.sh

echo "Files fixed and created in /home/jeremy/nm-setup/"
echo "Instructions to use on the target system:"
echo "1. Copy podman-compose.yml to the root directory: cp /home/jeremy/nm-setup/podman-compose.yml /root/nm-setup-xray/"
echo "2. Copy the fixed scripts: cp /home/jeremy/nm-setup/scripts/nm-*.sh /root/nm-setup-xray/scripts/"
echo "3. Make the scripts executable: chmod +x /root/nm-setup-xray/scripts/*.sh" 