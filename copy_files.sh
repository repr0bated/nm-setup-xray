#!/bin/bash
# Create a script to copy necessary files to the root nm-setup-xray directory

# Copy the podman-compatible compose file
sudo cp /home/jeremy/nm-setup/podman-compose.yml /root/nm-setup-xray/

# Copy the updated scripts
sudo cp /home/jeremy/nm-setup/scripts/nm-prepare.sh /root/nm-setup-xray/scripts/
sudo cp /home/jeremy/nm-setup/scripts/nm-setup.sh /root/nm-setup-xray/scripts/

# Make the scripts executable
sudo chmod 755 /root/nm-setup-xray/scripts/*.sh

echo "Files copied successfully to /root/nm-setup-xray/" 