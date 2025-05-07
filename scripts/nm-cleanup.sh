#!/bin/bash
set -e

# Arguments
REMOVE_STATE=false
while [ "$1" != "" ]; do
    case $1 in
        -a|--all)
            REMOVE_STATE=true
    esac
    shift
done

# Directory containing volume data
[ "${EUID:-$(id -u)}" -eq 0 ] \
    && NMDIR=/var/lib/netmaker \
    || NMDIR=$HOME/.local/share/netmaker

# Detect container runtime
if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    echo "Error: Neither Docker nor Podman is installed."
    exit 1
fi

echo "Using $RUNTIME for cleanup..."

# Remove systemd units
units=$(systemctl list-unit-files --all | grep 'netmaker-\|netclient-' | awk '{print $1}')
for unit in $units; do
    echo "Disabling and stopping $unit ..."
    systemctl disable --now $unit

    echo "Removing $unit"
    unit_path=$(systemctl show -P FragmentPath $unit)
    rm $unit_path
done
systemctl daemon-reload

# Remove previous pod if using podman
if [ "$RUNTIME" = "podman" ]; then
    echo "Removing netmaker pod (Podman)..."
    podman pod exists netmaker && podman pod rm -f netmaker
else
    # For Docker, stop and remove all netmaker containers
    echo "Removing netmaker containers (Docker)..."
    containers=$($RUNTIME ps -a --format '{{ .Names }}' | grep 'netmaker-\|netclient-')
    for container in $containers; do
        $RUNTIME rm -f $container || true
    done
fi

if [ $REMOVE_STATE = true ]; then
    # Remove volumes
    echo "Removing netmaker volumes..."
    $RUNTIME volume rm -f \
        netmaker-data \
        netmaker-certs \
        netmaker-mq-data \
        netmaker-mq-logs

    # Remove state directory
    echo "Removing netmaker directory..."
    rm -rf $NMDIR
fi
