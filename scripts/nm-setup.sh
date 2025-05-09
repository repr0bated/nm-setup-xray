#!/bin/bash
set -e
set -x

# This script sets up the Netmaker environment using Podman Compose or Docker Compose.

# --- Preliminary Cleanup (Best effort for old scripted setup) ---
echo "Attempting to clean up entities from any previous non-Compose setup..."

# Detect runtime for cleanup, default to docker if neither specifically found
CLEANUP_RUNTIME="podman"
if command -v podman >/dev/null 2>&1; then
    CLEANUP_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CLEANUP_RUNTIME="podman"
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
REPO_ROOT=$(cd "$SCRIPT_DIR_SETUP/.." && pwd)

# 1. Determine DOMAIN and MASTER_KEY for this setup session
SETUP_DOMAIN=$1 # Domain comes from the first argument to nm-setup.sh
if [ -z "$SETUP_DOMAIN" ]; then
    # This case should ideally be caught by nm-install.sh or direct user call validation
    # but as a fallback if nm-setup.sh is called directly without a domain:
    read -p "Enter the domain for Netmaker (e.g., yourdomain.com): " SETUP_DOMAIN
    if [ -z "$SETUP_DOMAIN" ]; then
        echo "Error: Domain is required for setup." >&2
        exit 1
    fi
fi

# Master Key handling logic (similar to what was in nm-setup.sh before for containers)
MASTER_KEY_PLACEHOLDER="TODO_REPLACE_MASTER_KEY"
SETUP_MASTER_KEY="${NM_MASTER_KEY:-$MASTER_KEY_PLACEHOLDER}" # Read from env var NM_MASTER_KEY, fallback to placeholder

if [ "$SETUP_MASTER_KEY" = "$MASTER_KEY_PLACEHOLDER" ]; then
  echo "WARNING: The default Netmaker MASTER_KEY is insecure or not set via NM_MASTER_KEY."
  read -p "Enter a new MASTER_KEY for Netmaker (at least 16 chars, leave blank to auto-generate): " user_master_key
  if [ -n "$user_master_key" ]; then
    if [ "${#user_master_key}" -lt 16 ]; then
      echo "Error: MASTER_KEY must be at least 16 characters long." >&2
      exit 1
    fi
    SETUP_MASTER_KEY="$user_master_key"
    echo "Using user-provided MASTER_KEY for this session."
  else
    SETUP_MASTER_KEY=$(openssl rand -hex 32) # Generate a 64-character hex key
    echo "Auto-generated a new MASTER_KEY for this session: $SETUP_MASTER_KEY"
  fi
  echo "----------------------------------------------------------------------"
  echo "IMPORTANT: Netmaker MASTER_KEY for this session: $SETUP_MASTER_KEY"
  echo "This will be written to the .env file by nm-prepare.sh."
  echo "Please ensure it is saved if it was auto-generated and you need it later."
  echo "----------------------------------------------------------------------"
else
  echo "Using MASTER_KEY from environment variable NM_MASTER_KEY for this session."
fi

# Call preparation script, passing determined DOMAIN and MASTER_KEY
echo "Running preparation script..."
if [ -f "$SCRIPT_DIR_SETUP/nm-prepare.sh" ]; then
    bash "$SCRIPT_DIR_SETUP/nm-prepare.sh" "$SETUP_DOMAIN" "$SETUP_MASTER_KEY"
else
    echo "Error: nm-prepare.sh not found in $SCRIPT_DIR_SETUP. Cannot proceed." >&2
    exit 1
fi

# Source .env file to get variables for messages, though compose will use it directly
if [ -f "$REPO_ROOT/.env" ]; then
    echo "Loading environment variables from .env file..."
    set -o allexport; source "$REPO_ROOT/.env"; set +o allexport
else
    echo "Warning: .env file not found. Compose might fail or use defaults."
fi

# 2. Detect Compose tool
COMPOSE_CMD=""
if command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo "Error: Neither docker-compose nor podman-compose found. Please install one to proceed." >&2
    exit 1
fi

echo "Using $COMPOSE_CMD for deployment..."

# 3. Run Compose up
# Assumes docker-compose.yml is in the current directory (root of the project)
cd "$REPO_ROOT"
echo "Working directory: $(pwd)"
echo "Checking for docker-compose.yml: $(ls -la docker-compose.yml || echo 'NOT FOUND')"
echo "Starting services with $COMPOSE_CMD up -d..."
$COMPOSE_CMD -f docker-compose.yml up -d

echo ""
echo "Netmaker services started via $COMPOSE_CMD."
echo "Check service status with: $COMPOSE_CMD ps"
echo "View logs with: $COMPOSE_CMD logs -f [service_name]"
echo ""
echo "Ensure your DNS (api.$DOMAIN, dashboard.$DOMAIN, etc.) points to this host."

# Persistence:
if [ "$COMPOSE_CMD" = "podman-compose" ]; then
    echo "For persistence with Podman, you might need to generate systemd units manually"
    echo "after services are up, or use 'podman-compose up --systemd' for systemd integration."
else
    echo "For Docker, restart policies in docker-compose.yml should handle service restarts."
fi
echo "after services are up, or use podman-compose features for systemd integration."
echo "For Docker, restart policies in docker-compose.yml should handle service restarts."

echo "Visit https://github.com/${GITHUB_REPO_USER:-repr0bated}/${GITHUB_REPO_NAME:-nm-setup-xray} for more information."
