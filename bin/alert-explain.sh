#!/usr/bin/env bash
# Print one alert code's catalog entry for the terminal (D44); read-only. usage: alert-explain.sh <CODE>   e.g. STL-ESC-210
[[ "${1:-}" =~ ^\[?\*?\*?[A-Za-z]{3}-[A-Za-z]{2,3}-[0-9]{3} ]] || { echo "usage: alert-explain.sh <CODE>   (for example STL-ESC-210)" >&2; exit 2; }
exec python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/alert_catalog.py" explain "$1"
