#!/usr/bin/env bash
# The config must be plain NAME=value lines (or comments/blank): a config that prints the expected line, exits early or runs code is not a fix (S6C-06).
! grep -aEvq '^[[:space:]]*(#.*|[A-Z_][A-Z0-9_]*=[A-Za-z0-9_./-]*)?[[:space:]]*$' deploy.conf || exit 1
[ "$(bash deploy.sh --dry-run)" = "would deploy to ./out" ] && echo "${BENCH_NONCE:-ok}"
