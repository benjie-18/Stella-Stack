#!/usr/bin/env bash
set -eu
. ./deploy.conf
[ "${1:-}" = --dry-run ] || { echo "only --dry-run is supported here" >&2; exit 2; }
echo "would deploy to $TARGET_DIR"
