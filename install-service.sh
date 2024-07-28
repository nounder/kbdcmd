#!/bin/sh

SERVICE_FILE=org.libred.kbdcmd.plist
DST_DIR=$HOME/Library/LaunchAgents

cp $SERVICE_FILE $DST_DIR/$SERVICE_FILE

chmod 644 $DST_DIR/$SERVICE_FILE

launchctl load $DST_DIR/$SERVICE_FILE

launchctl start
