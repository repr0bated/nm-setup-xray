#!/bin/bash
set -e

# Check if domain is provided
DOMAIN=$1
if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

# Set other parameters
SERVER_PORT=${2:-8081}
BROKER_PORT=${3:-8883}
DASHBOARD_PORT=${4:-8080}

# Repository information
REPO_USER="repr0bated"
REPO_NAME="nm-setup-xray"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/$REPO_USER/$REPO_NAME/$BRANCH/scripts"

# Temporary directory
TMP_DIR=$(mktemp -d)
trap 'rm -rf $TMP_DIR' EXIT

echo "Installing Netmaker with Xray using scripts from $REPO_USER/$REPO_NAME..."

# Download required scripts to temporary directory
echo "Downloading scripts into $TMP_DIR..."
for script in nm-prepare.sh nm-setup.sh nm-join.sh nm-persist.sh nm-routes.sh nm-cleanup.sh; do
    echo "Downloading $script..."
    curl -sfL "$BASE_URL/$script" -o "$TMP_DIR/$script"
    if [ ! -f "$TMP_DIR/$script" ]; then
        echo "ERROR: Failed to download $script from $BASE_URL/$script" >&2
        exit 1
    fi
    chmod +x "$TMP_DIR/$script"
done

echo "Downloaded scripts:
ls -l $TMP_DIR"

# Change to the temporary directory to ensure relative paths work
cd "$TMP_DIR"

# Run preparation script
echo "Running preparation script..."
# Now that we are in TMP_DIR, ./nm-prepare.sh should work
./nm-prepare.sh "$DOMAIN"

# Run setup script
echo "Running setup script..."
# Similarly, ./nm-setup.sh should work
./nm-setup.sh "$DOMAIN" "$SERVER_PORT" "$BROKER_PORT" "$DASHBOARD_PORT"

cd -

echo "Installation complete!"
echo ""
echo "To join a network, use:"
echo "  curl -sfL $BASE_URL/nm-join.sh | sudo bash -s - <TOKEN>"
echo ""
echo "To set up persistence (recommended), use:"
echo "  curl -sfL $BASE_URL/nm-persist.sh | sudo bash -s -"
echo ""
echo "To clean up the installation, use:"
echo "  curl -sfL $BASE_URL/nm-cleanup.sh | sudo bash -s -"
echo ""
echo "Visit https://github.com/$REPO_USER/$REPO_NAME for more information." 