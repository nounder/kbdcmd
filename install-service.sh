#!/bin/sh

SERVICE_FILE=org.libred.kbdcmd.plist
DST_DIR=$HOME/Library/LaunchAgents

cp $SERVICE_FILE $DST_DIR/$SERVICE_FILE

chmod 644 $DST_DIR/$SERVICE_FILE

# If you encounter "Load failed: 5: Input/output error", try:
# launchctl unload $HOME/Library/LaunchAgents/org.libred.kbdcmd.plist

launchctl load $DST_DIR/$SERVICE_FILE

launchctl start org.libred.kbdcmd.plist
