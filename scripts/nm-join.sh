#!/bin/bash
set -e

# Arguments
TOKEN=$1

# Fetch api server certificate
CERT_FILE=/tmp/nm-${SERVER%:*}.pem
SERVER=$(echo $TOKEN | base64 -d | jq -r .apiconnstring)
openssl s_client -showcerts -connect $SERVER </dev/null 2>/dev/null | openssl x509 -outform PEM > $CERT_FILE

# Generate random postfix for container name
CONTAINER_NAME=netclient-$(openssl rand -hex 4)

# Detect container runtime
if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    echo "Error: Neither Docker nor Podman is installed."
    exit 1
fi

echo "Using $RUNTIME to join network..."

# Create netclient container
$RUNTIME create --name $CONTAINER_NAME \
    -e TOKEN=$TOKEN \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --cap-add SYS_MODULE \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv6.conf.all.forwarding=1 \
    gravitl/netclient:latest

# Append certificate to container system certificates
$RUNTIME cp $CONTAINER_NAME:/etc/ssl/certs/ca-certificates.crt /tmp/nc-certs.crt
cat $CERT_FILE >> /tmp/nc-certs.crt
$RUNTIME cp /tmp/nc-certs.crt $CONTAINER_NAME:/etc/ssl/certs/ca-certificates.crt

# Start netclient container
$RUNTIME start $CONTAINER_NAME

echo "Network client started as $CONTAINER_NAME"
