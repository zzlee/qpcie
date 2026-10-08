#!/bin/bash
set -e
echo "Starting full build pipeline..."
./scripts/build_zu4ev.sh
./scripts/build_zu4ev_fsbl.sh
./scripts/inject_upgrade_daemon_to_image_ub.sh
./scripts/build_zu4ev_sd_installer.sh
echo "All done!"
