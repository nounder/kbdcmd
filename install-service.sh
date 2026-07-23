#!/bin/sh
set -eu

SERVICE_FILE=org.libred.kbdcmd.plist
LABEL=org.libred.kbdcmd
DST_DIR=$HOME/Library/LaunchAgents
DST=$DST_DIR/$SERVICE_FILE
DOMAIN=gui/$(id -u)

mkdir -p "$DST_DIR"
cp "$SERVICE_FILE" "$DST"
chmod 644 "$DST"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

launchctl bootstrap "$DOMAIN" "$DST"
launchctl kickstart "$DOMAIN/$LABEL"

echo "Installed and started $LABEL"
