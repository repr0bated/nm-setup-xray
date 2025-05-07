#!/bin/bash
set -e
echo "Starting script updates..."

# Update nm-prepare.sh by adding docker-compose.yml creation
echo "Updating nm-prepare.sh..."
grep -q "Creating docker-compose.yml for podman-compose" scripts/nm-prepare.sh || {
  cat << 'PREPARE_APPEND' >> scripts/nm-prepare.sh

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
      - SERVER_NAME=\$DOMAIN
      - MASTER_KEY=TODO_REPLACE_MASTER_KEY
      - SERVER_HOST=api.\$DOMAIN
      - DNS_MODE=off
      - CLIENT_MODE=on
      - DATABASE=sqlite
      - DISABLE_REMOTE_IP_CHECK=on
      - API_PORT=8081
      - CORS_ALLOWED_ORIGIN=http://localhost:3000
      - MQ_HOST=127.0.0.1
      - MQ_PORT=1883
      - SERVER_HTTP_HOST=api.\$DOMAIN
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
      - BACKEND_URL=https://api.\$DOMAIN:8443

  netmaker-mq:
    <<: *default-pod-config
    image: eclipse-mosquitto:2.0-openssl
    container_name: netmaker-mq
    restart: unless-stopped
    volumes:
      - netmaker-mq-data:/mosquitto/data
      - netmaker-mq-logs:/mosquitto/log
      - \$NMDIR/mosquitto.conf:/mosquitto/config/mosquitto.conf

  netmaker-proxy:
    <<: *default-pod-config
    image: nginx:latest
    container_name: netmaker-proxy
    restart: unless-stopped
    volumes:
      - \$NMDIR/nginx.conf:/etc/nginx/nginx.conf:ro
      - \$NMDIR/selfsigned.key:/etc/nginx/ssl/selfsigned.key
      - \$NMDIR/selfsigned.crt:/etc/nginx/ssl/selfsigned.crt
    ports:
      - "8443:8443"
      - "8080:8080"

  netmaker-xray:
    <<: *default-pod-config
    image: ghcr.io/xtls/xray-core:sha-59aa5e1-ls
    container_name: netmaker-xray
    restart: unless-stopped
    volumes:
      - \$NMDIR/xray/config.json:/etc/xray/config.json
      - \$NMDIR/xray/ssl:/etc/xray/ssl
    ports:
      - "443:443"

volumes:
  netmaker-data:
  netmaker-certs:
  netmaker-mq-data:
  netmaker-mq-logs:
COMPOSEEOF

echo "Created docker-compose.yml in \$NMDIR/config/"
PREPARE_APPEND
}

# Create a patch file for nm-setup.sh
echo "Creating patch for nm-setup.sh..."
cat > nm-setup.patch << 'PATCH_CONTENT'
--- nm-setup.sh.orig
+++ nm-setup.sh
@@ -27,6 +27,37 @@
 
 echo "Using $RUNTIME for deployment..."
 
+# Check for compose tools
+COMPOSE_CMD=""
+if command -v podman-compose >/dev/null 2>&1; then
+    COMPOSE_CMD="podman-compose"
+    echo "Found podman-compose, using it for deployment..."
+elif command -v docker-compose >/dev/null 2>&1; then
+    COMPOSE_CMD="docker-compose"
+    echo "Found docker-compose, using it for deployment..."
+fi
+
+# Debug info - print current directory and check for docker-compose files
+echo "Current directory: $(pwd)"
+echo "NMDIR is set to: $NMDIR"
+
+if [ -n "$COMPOSE_CMD" ] && [ -f "$NMDIR/config/docker-compose.yml" ]; then
+    echo "Using $COMPOSE_CMD with configuration in $NMDIR/config/docker-compose.yml"
+    
+    # Change to the config directory
+    cd "$NMDIR/config"
+    
+    # Run the compose command
+    echo "Running: $COMPOSE_CMD -f docker-compose.yml up -d"
+    $COMPOSE_CMD -f docker-compose.yml up -d
+    
+    # Return to the original directory
+    cd - > /dev/null
+    
+    echo "Setup complete! Netmaker is running with Xray on port 443."
+    exit 0
+fi
+
 # Create empty pod if using podman
 if [ "$RUNTIME" = "podman" ]; then
     echo "Creating netmaker pod ..."
PATCH_CONTENT

# Apply the patch to nm-setup.sh
echo "Applying patch to nm-setup.sh..."
patch -b scripts/nm-setup.sh nm-setup.patch || {
  echo "Patch failed, trying direct approach..."
  
  # Create a backup of nm-setup.sh
  cp scripts/nm-setup.sh scripts/nm-setup.sh.bak
  
  # Insert the compose handling code directly
  sed -i '27i\
# Check for compose tools\
COMPOSE_CMD=""\
if command -v podman-compose >/dev/null 2>&1; then\
    COMPOSE_CMD="podman-compose"\
    echo "Found podman-compose, using it for deployment..."\
elif command -v docker-compose >/dev/null 2>&1; then\
    COMPOSE_CMD="docker-compose"\
    echo "Found docker-compose, using it for deployment..."\
fi\
\
# Debug info - print current directory and check for docker-compose files\
echo "Current directory: $(pwd)"\
echo "NMDIR is set to: $NMDIR"\
\
if [ -n "$COMPOSE_CMD" ] && [ -f "$NMDIR/config/docker-compose.yml" ]; then\
    echo "Using $COMPOSE_CMD with configuration in $NMDIR/config/docker-compose.yml"\
    \
    # Change to the config directory\
    cd "$NMDIR/config"\
    \
    # Run the compose command\
    echo "Running: $COMPOSE_CMD -f docker-compose.yml up -d"\
    $COMPOSE_CMD -f docker-compose.yml up -d\
    \
    # Return to the original directory\
    cd - > /dev/null\
    \
    echo "Setup complete! Netmaker is running with Xray on port 443."\
    exit 0\
fi\
' scripts/nm-setup.sh
}

# Make scripts executable
chmod +x scripts/nm-prepare.sh
chmod +x scripts/nm-setup.sh

echo "Scripts updated successfully!"
ls -la scripts/nm-prepare.sh scripts/nm-setup.sh
