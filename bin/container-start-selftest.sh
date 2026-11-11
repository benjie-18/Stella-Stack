#!/usr/bin/env bash
# Hermetic self-test for bin/container-start.sh (S7, S23) and the devcontainer postStartCommand order: a copy of the
# script with the apply step pointed at a stub, scratch HOME and state, stub crontab, jq, hermes, sudo and tmux.
# Checks: a missing skill source, a failing jq, crontab or apply step never stop later steps and are named on stderr;
# a jq failure keeps the old OpenCode config; an apply failure alerts once an hour; postStart starts the gateway
# unless the firewall failed, whatever cron and container-start return; git safe.directory is set once (D48).
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ws/bin" "$T/bin" "$T/home/.hermes/skills/writing/anti-ai-slop-writing" "$T/sup/state"
echo "skill" > "$T/home/.hermes/skills/writing/anti-ai-slop-writing/SKILL.md"
sed -e "s#/workspace/bin/apply-hermes-local.sh#$T/bin/apply-hermes-local.sh#g" -e "s#/workspace/bin/omniroute-ctl.sh#$T/bin/omniroute-ctl.sh#g" -e "s#/workspace/docs/hermes-local/fallback-routing.json#$T/fb.json#g" "${CS_SRC:-/workspace/bin/container-start.sh}" > "$T/ws/bin/cs.sh"
REAL_JQ=$(command -v jq)
cat > "$T/bin/jq" <<S
#!/usr/bin/env bash
[ -z "\${FAKE_JQ_FAIL:-}" ] || { echo '{"partial'; exit 5; }
exec $REAL_JQ "\$@"
S
printf '#!/usr/bin/env bash\n[ -z "${FAKE_CRONTAB_FAIL:-}" ]\n' > "$T/bin/crontab"
printf '#!/usr/bin/env bash\necho ran > %s/apply.ran\n[ -z "${FAKE_APPLY_FAIL:-}" ] || exit 3\n' "$T" > "$T/bin/apply-hermes-local.sh"
printf '#!/usr/bin/env bash\n[ "$1" = send ] && printf "%%s\\n" "$*" >> %s/sends\nexit 0\n' "$T" > "$T/bin/hermes"
printf '#!/usr/bin/env bash\necho "$*" >> %s/gateway.started\n[ -z "${FAKE_GW_FAIL:-}" ]\n' "$T" > "$T/bin/omniroute-ctl.sh"
chmod +x "$T/bin/"*
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
CFG="$T/home/.config/opencode/opencode.json"
run() { rm -f "$T/apply.ran"; env HOME="$T/home" PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup" ALERT_TARGET="stub:#alerts" "$@" \
  bash "$T/ws/bin/cs.sh" > "$T/out" 2> "$T/err"; rc=$?; }

run
ok '[ "$rc" = 0 ] && ! grep -v setlocale "$T/err" | grep -q . && jq -e ".model" "$CFG" >/dev/null && [ -f "$T/home/.config/opencode/skills/anti-ai-slop-writing/SKILL.md" ] && [ -f "$T/apply.ran" ]' "all steps succeed: exit 0, config and skill in place, apply ran"
ok '[ ! -e "$CFG.tmp" ] && [ ! -e "$T/sends" ]' "no temp file left, no alert"
ok '[ "$(HOME="$T/home" git config --global --get-all safe.directory)" = "$T/ws" ]' "D48: git safe.directory is the stack folder derived from the script's place, not typed"
run
ok '[ "$rc" = 0 ] && [ "$(HOME="$T/home" git config --global --get-all safe.directory | wc -l)" = 1 ]' "D48: a second start adds nothing (idempotent)"
cp "$CFG" "$T/cfg.good"
run FAKE_JQ_FAIL=1
ok '[ "$rc" != 0 ] && cmp -s "$CFG" "$T/cfg.good" && [ ! -e "$CFG.tmp" ] && grep -q "opencode" "$T/err" && [ -f "$T/apply.ran" ]' "S23: jq fails: the old config is kept (not truncated), the step is named, apply still runs (exit $rc)"
mv "$T/home/.hermes/skills/writing/anti-ai-slop-writing" "$T/skill.off"
run
ok '[ "$rc" != 0 ] && grep -q "anti-ai-slop-writing" "$T/err" && [ -f "$T/apply.ran" ]' "S7: skill source missing: logged, apply still runs, exit $rc"
mv "$T/skill.off" "$T/home/.hermes/skills/writing/anti-ai-slop-writing"
run FAKE_CRONTAB_FAIL=1
ok '[ "$rc" != 0 ] && grep -q "crontab" "$T/err" && [ -f "$T/apply.ran" ]' "S7: crontab fails: logged, the later steps run (exit $rc)"
run FAKE_APPLY_FAIL=1; run FAKE_APPLY_FAIL=1
ok '[ "$rc" != 0 ] && grep -q "apply-hermes-local.sh failed (exit 3)" "$T/err" && [ "$(grep -c "guards may not be registered" "$T/sends" 2>/dev/null)" = 1 ]' "apply fails: logged, one #alerts line naming the guards across two runs (rate-limited), exit $rc"

# D93: the fallback gateway starts at container start when the fallback is enabled (best effort, in the background, never fatal)
gw() { rm -f "$T/gateway.started"; run "$@"; for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$T/gateway.started" ] && break; sleep 0.3; done; }
echo '{"schema_version":1,"enabled":true}' > "$T/fb.json"; gw
ok '[ "$rc" = 0 ] && [ "$(cat "$T/gateway.started" 2>/dev/null)" = start ]' "D93: fallback enabled: the gateway is started (omniroute-ctl.sh start), the other steps are unaffected (exit $rc)"
echo '{"schema_version":1,"enabled":false}' > "$T/fb.json"; gw; sleep 1
ok '[ "$rc" = 0 ] && [ ! -e "$T/gateway.started" ]' "D93: fallback disabled: the gateway is not started"
rm -f "$T/fb.json"; gw; sleep 1
ok '[ "$rc" = 0 ] && [ ! -e "$T/gateway.started" ] && ! grep -v setlocale "$T/err" | grep -q .' "D93: no fallback config: nothing started, no error"
echo '{"schema_version":1,"enabled":true}' > "$T/fb.json"; gw FAKE_GW_FAIL=1
ok '[ "$rc" = 0 ] && [ -f "$T/apply.ran" ]' "D93: a gateway that fails to start does not fail container start or skip the apply step (exit $rc)"
run FAKE_JQ_FAIL=1; ok '[ "$rc" != 0 ] && [ -f "$T/apply.ran" ]' "D93: with jq failing the later steps still run"

# postStartCommand: the gateway session starts unless the firewall failed.
PS=$(jq -r .postStartCommand /workspace/.devcontainer/devcontainer.json)
PS=${PS//\/workspace\/bin\/container-start.sh/$T/bin/cs-stub}
printf '#!/usr/bin/env bash\necho "sudo $*" >> %s/order\ncase "$1" in */init-firewall.sh) exit "${FAKE_FW_RC:-0}";; */service) exit "${FAKE_CRON_RC:-0}";; esac\n' "$T" > "$T/bin/sudo"
printf '#!/usr/bin/env bash\necho container-start >> %s/order\nexit "${FAKE_CS_RC:-0}"\n' "$T" > "$T/bin/cs-stub"
printf '#!/usr/bin/env bash\n[ "$1" = has-session ] && exit 1\necho "tmux $1" >> %s/order\n' "$T" > "$T/bin/tmux"
chmod +x "$T/bin/"*
post() { : > "$T/order"; env PATH="$T/bin:$PATH" "$@" sh -c "$PS" >/dev/null 2>&1; rc=$?; order=$(cut -d' ' -f1-2 "$T/order" | tr '\n' ','); }
post
ok '[ "$rc" = 0 ] && [ "$order" = "sudo /usr/local/bin/init-firewall.sh,sudo /usr/sbin/service,container-start,tmux new-session," ]' "postStart: firewall, cron, container-start, gateway, in that order (exit $rc)"
post FAKE_FW_RC=1
ok '[ "$rc" != 0 ] && [ "$order" = "sudo /usr/local/bin/init-firewall.sh," ]' "postStart: firewall fails: nothing else runs, no gateway, exit $rc"
post FAKE_CRON_RC=1
ok '[ "$rc" != 0 ] && [[ "$order" == *"container-start,tmux new-session,"* ]]' "postStart: cron fails: container-start and the gateway still start, exit $rc"
post FAKE_CS_RC=1
ok '[ "$rc" != 0 ] && [[ "$order" == *"tmux new-session,"* ]]' "postStart: container-start fails: the gateway still starts, exit $rc"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
