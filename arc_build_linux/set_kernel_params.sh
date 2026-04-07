#!/bin/bash
# Sets kernel parameters required to prevent Arc connection timeouts.
# Run on the edge device (NUC) after cloning/pulling the repo.

set -e

echo "Writing kernel parameters to /etc/sysctl.conf..."
printf '\nfs.inotify.max_user_instances=8192\nfs.inotify.max_user_watches=524288\nfs.file-max = 100000\n' \
    | sudo tee -a /etc/sysctl.conf

echo "Applying sysctl settings..."
sudo sysctl -p

echo "Restarting k3s..."
sudo systemctl restart k3s

echo "Done."
