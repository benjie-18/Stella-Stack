#!/usr/bin/env bash
# Owner-facing #alerts messages from the catalog (D44): docs/hermes-local/alert-catalog.json, rendered by bin/alert_catalog.py.
# Sourced: alert_text <CODE> [key=value ...]     the plain-language body on stdout; one line, code first, with every raw
#                                                 key=value to .supervisor/logs/alerts.log. Never fails, never empty.
#          stella_alert <CODE> [key=value ...]   alert_text, then `hermes send` to ${ALERT_TARGET:-discord:#alerts};
#                                                 returns the send's exit code
# Run:     alert.sh <CODE> [key=value ...]        stella_alert (the Windows recovery script calls it through docker exec)
#          alert.sh --sample <CODE>               sample values, "(sample)" in the title, posted to #alerts: run by hand only
# Callers keep their own triggers, rate limits and dedupe keys (once_per_hour, watchdog-open/); nothing here depends on
# the rendered text. Keys: since=/now= (UTC ISO or epoch), error=<raw> (logged, posted only as a plain phrase), resolved=1.
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
ALERT_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

alert_text() {
  local out
  out=$(python3 -I "$ALERT_BIN/alert_catalog.py" render "$@" 2>/dev/null)
  if [ -z "$out" ]; then   # the renderer itself failed: still say something, with the generic code
    out="⚠️ Stella: something needs a look  **[STL-GEN-000]**
A part of Stella reported a problem ($1), but the alert could not be written out.
What to do: see STL-GEN-000 in docs/alert-codes.md."
  fi
  printf '%s\n' "$out"
}

stella_alert() { hermes send --to "${ALERT_TARGET:-discord:#alerts}" --quiet "$(alert_text "$@")"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  export LC_ALL=C.UTF-8
  case "${1:-}" in
    --sample) [ -n "${2:-}" ] || { echo "usage: alert.sh --sample <CODE>" >&2; exit 2; }
              hermes send --to "${ALERT_TARGET:-discord:#alerts}" --quiet "$(python3 -I "$ALERT_BIN/alert_catalog.py" sample "$2")" ;;
    STL-*)    stella_alert "$@" ;;
    *)        echo "usage: alert.sh <CODE> [key=value ...] | alert.sh --sample <CODE>" >&2; exit 2 ;;
  esac
  exit $?
fi
