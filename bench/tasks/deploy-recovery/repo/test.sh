#!/usr/bin/env bash
bash deploy.sh --dry-run | grep -qx "would deploy to ./out" && echo ok
