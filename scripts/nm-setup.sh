#!/bin/bash
set -e

# This script sets up the Netmaker environment using Docker Compose or Podman Compose.

# --- Preliminary Cleanup (Best effort for old scripted setup) ---
echo "Attempting to clean up entities from any previous non-Compose setup..."

# Detect runtime for cleanup, default to docker if neither specifically found
CLEANUP_RUNTIME="docker"
if command -v podman >/dev/null 2>&1; then
    CLEANUP_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CLEANUP_RUNTIME="docker"
fi

if [ "$CLEANUP_RUNTIME" = "podman" ]; then
    echo "Cleaning up old Podman resources..."
    podman pod rm -f netmaker || true
    # Individual containers (if not in pod) - less likely with old scripts but good to check
    for container_name in netmaker-server netmaker-mq netmaker-ui netmaker-proxy netmaker-xray netclient; do
      podman rm -f "$(podman ps -aq --filter name=^${container_name})" || true
    done
else # Docker or default
    echo "Cleaning up old Docker resources..."
    for container_name in netmaker-server netmaker-mq netmaker-ui netmaker-proxy netmaker-xray netclient; do
      docker rm -f "$(docker ps -aq --filter name=^${container_name})" || true
    done
fi

# Common volumes from old script (best effort, names might vary if user changed them)
for volume_name in netmaker-data netmaker-certs netmaker-mq-data netmaker-mq-logs; do
  $CLEANUP_RUNTIME volume rm -f "$volume_name" || true
done
echo "Preliminary cleanup attempt finished."

# --- End Preliminary Cleanup ---

SCRIPT_DIR_SETUP=$(dirname "$0")

# 1. Run preparation script to create .env, configs, and certs
echo "Running preparation script..."
if [ -f "$SCRIPT_DIR_SETUP/nm-prepare.sh" ]; then
    # Pass current environment variables, so NM_DOMAIN and NM_MASTER_KEY can be used if set
    env NM_DOMAIN="$NM_DOMAIN" NM_MASTER_KEY="$NM_MASTER_KEY" bash "$SCRIPT_DIR_SETUP/nm-prepare.sh"
else
    echo "Error: nm-prepare.sh not found in $SCRIPT_DIR_SETUP. Cannot proceed." >&2
    exit 1
fi

# Source .env file to get variables for messages, though compose will use it directly
if [ -f .env ]; then
    echo "Loading environment variables from .env file..."
    set -o allexport; source .env; set +o allexport
else
    echo "Warning: .env file not found. Compose might fail or use defaults."
fi

# 2. Detect Compose tool
COMPOSE_CMD=""
if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_CMD="podman-compose"
else
    echo "Error: Neither docker-compose nor podman-compose found. Please install one to proceed." >&2
    exit 1
fi

echo "Using $COMPOSE_CMD for deployment..."

# 3. Run Compose up
# Assumes docker-compose.yml is in the current directory (root of the project)
echo "Starting services with $COMPOSE_CMD up -d..."
$COMPOSE_CMD -f docker-compose.yml up -d

echo ""
echo "Netmaker services started via $COMPOSE_CMD."
echo "Check service status with: $COMPOSE_CMD ps"
echo "View logs with: $COMPOSE_CMD logs -f [service_name]"
echo ""
echo "Ensure your DNS (api.$DOMAIN, dashboard.$DOMAIN, etc.) points to this host."

# Persistence:
# For Docker: restart policies in docker-compose.yml handle this.
# For Podman: user can run 'podman-compose up --systemd' or generate systemd units via 'podman generate systemd ...' for the pod/containers if podman-compose creates them that way.
# This script will not automatically set up systemd units for compose for now.
# The old nm-persist.sh is not compatible with a compose setup directly.

echo "For persistence with Podman, you might need to generate systemd units manually"
echo "after services are up, or use podman-compose features for systemd integration."
echo "For Docker, restart policies in docker-compose.yml should handle service restarts."

echo "Visit https://github.com/${GITHUB_REPO_USER:-repr0bated}/${GITHUB_REPO_NAME:-nm-setup-xray} for more information."
