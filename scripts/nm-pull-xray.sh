#!/bin/bash
set -e

IMAGE="ghcr.io/xtls/xray-core:sha-59aa5e1-ls"

# Check if Docker is available
if command -v docker >/dev/null 2>&1; then
    echo "Docker detected, pulling image using Docker..."
    docker pull $IMAGE
    RUNTIME="docker"
# Check if Podman is available
elif command -v podman >/dev/null 2>&1; then
    echo "Podman detected, pulling image using Podman..."
    podman pull $IMAGE
    RUNTIME="podman"
else
    echo "Error: Neither Docker nor Podman is installed."
    exit 1
fi

echo "Successfully pulled $IMAGE using $RUNTIME" 