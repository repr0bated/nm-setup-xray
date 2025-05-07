#!/bin/bash

# Constants
NETMAKER_DIR=/var/lib/netmaker
SYSTEMD_UNIT_DIR=/etc/systemd/system

# Detect container runtime
if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    echo "Error: Neither Docker nor Podman is installed."
    exit 1
fi

echo "Using $RUNTIME for persistence setup..."

# Gather applicable containers
containers=$($RUNTIME ps --format '{{ .Names }}' | grep 'netmaker-\|netclient-')

# For each container
for container in $containers; do
    # Generate container service file if not exists
    unit_file=$SYSTEMD_UNIT_DIR/$container.service
    
    if [ "$RUNTIME" = "podman" ]; then
        [ ! -f $unit_file ] && podman generate systemd -n $container > $unit_file
    else
        # For Docker we need to create systemd files manually
        if [ ! -f $unit_file ]; then
            cat << EOF > $unit_file
[Unit]
Description=$container container
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
ExecStart=$RUNTIME start $container
ExecStop=$RUNTIME stop -t 10 $container
Type=forking

[Install]
WantedBy=multi-user.target
EOF
        fi
    fi

    # Reload unit files
    systemctl daemon-reload

    # Enable and start service
    systemctl enable --now $container
done

# Get route sync script
curl -sfL --create-dirs -O --output-dir $NETMAKER_DIR https://raw.githubusercontent.com/repr0bated/nm-setup-xray/main/scripts/nm-routes.sh
chmod a+x $NETMAKER_DIR/nm-routes.sh

# Create runtime specific routes script
cat << EOF > $NETMAKER_DIR/nm-routes-runtime.sh
#!/bin/bash
RUNTIME=$RUNTIME
export RUNTIME
$NETMAKER_DIR/nm-routes.sh
EOF
chmod a+x $NETMAKER_DIR/nm-routes-runtime.sh

# Generate service and timer unit files for route syncing
[ ! -f $SYSTEMD_UNIT_DIR/netmaker-routes.service ] && cat << EOF > $SYSTEMD_UNIT_DIR/netmaker-routes.service
[Unit]
Description=Synchronize container routes
Wants=network.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$NETMAKER_DIR/nm-routes-runtime.sh
EOF

[ ! -f $SYSTEMD_UNIT_DIR/netmaker-routes.timer ] && cat << EOF > $SYSTEMD_UNIT_DIR/netmaker-routes.timer
[Unit]
Description=Periodic route synchronization

[Timer]
OnCalendar=*:*:00/30
AccuracySec=1sec
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Reload unit files
systemctl daemon-reload

# Enable and start timer
systemctl enable --now netmaker-routes.timer
