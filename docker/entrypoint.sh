#!/bin/sh
# Ensure /data is writable by the app user (nobody).
# Docker volumes are often root-owned; the app runs as nobody and needs to
# create the SQLite DB and batch files under /data.
set -e
if [ -d /data ]; then
  chown -R nobody:nogroup /data
fi
exec runuser -u nobody -- "$@"
