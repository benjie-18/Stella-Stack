#!/usr/bin/env bash
# OmniRoute gateway control (T14). The install is outside the repo (~/.hermes/omniroute, pinned by its package-lock: version and
# integrity are checked here); its data, including provider keys, stays in its own store (data/, mode 700). Loopback only, the
# inference plane needs an API key, compression off, no update check.
#   omniroute-ctl.sh start    start in the background (log: .scratch/omniroute.log), then run status
#   omniroute-ctl.sh status   exit 0 only if: pinned version+integrity, every listener of the process on loopback,
#                             REQUIRE_API_KEY on, compression off in its settings, /v1/models refuses an unauthenticated call
#   omniroute-ctl.sh stop
# Not tested hermetically (needs the real install); the live run is recorded in PLAN.md (T14).
set -uo pipefail
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
H=/home/node/.hermes/omniroute; PIN_VERSION=3.8.53
PIN_INTEGRITY='sha512-vHne9/aKN1ULaZijd1pnYnYCp6taAVW6/ERn0CoGv/8fLMw+Hjq/hWy4aHWYT48RWLZZ8ykBAcKGjlZbBCtVZg=='
PORT=${OMNIROUTE_PORT:-20128}
env_() { DATA_DIR=$H/data OMNIROUTE_SERVER_HOST=127.0.0.1 REQUIRE_API_KEY=true OMNIROUTE_NO_UPDATE_NOTIFIER=1 "$@"; }
pid() { ss -ltnp 2>/dev/null | sed -n "s/.*127.0.0.1:$PORT .*pid=\([0-9]*\).*/\1/p" | head -1; }
status() {
  local bad=0 v i p
  v=$(jq -r .version "$H/node_modules/omniroute/package.json" 2>/dev/null); i=$(jq -r '.packages["node_modules/omniroute"].integrity' "$H/package-lock.json" 2>/dev/null)
  [ "$v" = "$PIN_VERSION" ] && [ "$i" = "$PIN_INTEGRITY" ] && echo "ok   pinned $v, integrity matches" || { echo "FAIL version/integrity ($v)"; bad=1; }
  p=$(pid); [ -n "$p" ] || { echo "FAIL not listening on 127.0.0.1:$PORT"; return 1; }
  local pids; pids=$(pgrep -P "$p" 2>/dev/null; echo "$p")
  local wide; wide=$(ss -ltnp 2>/dev/null | grep -E "pid=($(echo $pids | tr ' ' '|'))[,)]" | grep -vE ' 127\.0\.0\.1:| \[::1\]:' || true)
  [ -z "$wide" ] && echo "ok   every listener of the process is on loopback" || { echo "FAIL non-loopback listener: $wide"; bad=1; }
  c=$(python3 -I - "$H/data/storage.sqlite" <<'P'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(",".join(f"{k}={v}" for k, v in c.execute("select key, value from key_value where namespace='compression' and key in ('enabled','defaultMode')")))
P
)
  [[ "$c" == *enabled=false* && "$c" == *defaultMode=\"off\"* ]] && echo "ok   compression off ($c)" || { echo "FAIL compression not off ($c)"; bad=1; }
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models")" = 401 ] && echo "ok   /v1/models refuses a call without a key (401)" || { echo "FAIL /v1/models answered without a key"; bad=1; }
  return $bad
}
case ${1:-} in
  start) [ -z "$(pid)" ] || { echo "already listening"; status; exit $?; }
    ( cd "$H" && env_ setsid nohup node node_modules/omniroute/bin/omniroute.mjs serve --no-open --no-tray --port "$PORT" --log >/workspace/.scratch/omniroute.log 2>&1 & )
    for _ in $(seq 60); do [ -n "$(pid)" ] && curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/health" && break; sleep 2; done; status;;
  status) status;;
  stop) p=$(pid); [ -n "$p" ] || { echo "not running"; exit 0; }
    pp=$(ps -o ppid= -p "$p" | tr -d ' ')   # the launcher restarts a killed server, so it goes first
    tr '\0' ' ' <"/proc/$pp/cmdline" 2>/dev/null | grep -q 'omniroute.mjs serve' && kill "$pp"
    kill "$p" && echo stopped;;
  *) sed -n '2,10p' "$0"; exit 2;;
esac
