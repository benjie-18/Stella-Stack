#!/usr/bin/env bash
# Runs inside tmux session "hermes": restart the gateway when it exits, so a crash does not close the window.
# --external-supervisor: this loop owns the gateway, so in-chat restarts/updates exit back here instead of detaching.
while true; do
  hermes gateway run --external-supervisor
  rc=$?
  echo "$(date -u +%FT%TZ) hermes gateway exited rc=$rc; restarting in 10s" >> ~/.hermes/logs/gateway-restarts.log
  sleep 10
done
