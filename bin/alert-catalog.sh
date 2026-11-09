#!/usr/bin/env bash
# The alert catalog's generated troubleshooting table (D44). usage: alert-catalog.sh --docs    write docs/alert-codes.md
#                                                                    alert-catalog.sh --check   exit 1 if it is out of date or the catalog is invalid
set -euo pipefail
B="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; out="$B/../docs/alert-codes.md"
case "${1:-}" in
  --docs)  python3 -I "$B/alert_catalog.py" validate >/dev/null || { python3 -I "$B/alert_catalog.py" validate >&2; exit 1; }
           python3 -I "$B/alert_catalog.py" docs >"$out.tmp" && mv "$out.tmp" "$out" && echo "wrote docs/alert-codes.md" ;;
  --check) python3 -I "$B/alert_catalog.py" validate && cmp -s "$out" <(python3 -I "$B/alert_catalog.py" docs) \
             || { echo "docs/alert-codes.md is out of date: run bin/alert-catalog.sh --docs" >&2; exit 1; } ;;
  *)       echo "usage: alert-catalog.sh --docs | --check" >&2; exit 2 ;;
esac
