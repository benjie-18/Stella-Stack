#!/usr/bin/env bash
# Hermetic self-test for bin/compare.py (F2c item E), no model call, in a scratch root (a copy of bin, .stella, docs; its own HOME and
# temp). Planted data with a seeded generator: the t quantile and pass^k against known values, the paired mean difference and its 95%
# interval against a hand calculation, a clear gain and a clear loss, a cheaper model inside the margin (non_inferior; the same data
# not cheaper is inconclusive), pure noise (inconclusive), too few tasks (min_sample), the regression set (a failing task refuses
# whatever the mean), determinism (same input, same output, any order), the benchmark reader (foreign install, invalid record and an
# unreadable file are ignored, fail closed), routing_stats (prior below the minimum sample, benchmark mean above), the fake entry (a
# new role, connection and model in a scratch benchmark file, no code change), parameters read from model-check.json (an edit flips
# a decision), and the CLI's exit codes and catalog codes. Nothing here names a real role, connection or model.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/compare-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK
fails=0
ok() { if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
ed() { local f=$R/.stella/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }
cp_() { python3 -I -B "$R/bin/compare.py" "$@" 2>"$T/err"; }   # the output on stdout, the catalog line in $T/err
py() { python3 -I -B "$T/t.py" "$R" "$@"; }
IID=$(jq -r .install_id "$R/.stella/install.json")
BF=$R/$(ix .benchmark_results)

cat >"$T/t.py" <<'P'
import json, random, sys
sys.path.insert(0, sys.argv[1] + "/bin")
import compare
case = sys.argv[2]
PAR = {"confidence": 0.95, "trials": 5, "pass_k": 3, "margin": 0.05, "min_tasks": 8, "routing_min_tasks": 5, "stale_catalog_days": 14,
       "regression_set": {"min_pass_rate": 1.0}}

def arm(means, trials=3, noise=0.0, seed=1):
    """Records of one arm: per task, `trials` scores around the task's mean (clamped 0..1)."""
    rg, out = random.Random(seed), []
    for t, m in enumerate(means):
        for k in range(trials):
            s = min(1.0, max(0.0, m + rg.uniform(-noise, noise)))
            out.append({"task": f"t{t}", "trial": k, "passed": s >= 0.5, "score": s})
    return out

def base(n, seed):
    rg = random.Random(seed)
    return [rg.uniform(0.4, 0.9) for _ in range(n)]

def near(x, y, e):
    return abs(x - y) <= e

if case == "tquant":
    for df, want in ((1, 12.7062), (2, 4.3027), (4, 2.7764), (9, 2.2622), (30, 2.0423), (1000, 1.9623)):
        assert near(compare.t_quantile(0.975, df), want, 1e-3), (df, compare.t_quantile(0.975, df))
    assert near(compare.t_quantile(0.995, 5), 4.0321, 1e-3)
elif case == "passk":
    rs = [{"task": "a", "trial": i, "passed": i < 3} for i in range(4)] + [{"task": "b", "trial": i, "passed": True} for i in range(4)]
    assert near(compare.pass_k(rs, 2), (0.5 + 1.0) / 2, 1e-12), compare.pass_k(rs, 2)
    assert compare.pass_k(rs, 5) is None   # no task has five trials: no number rather than a made-up one
elif case == "ci":
    d = [0.1, 0.2, 0.3, 0.4, 0.5]
    a = [{"task": f"t{i}", "trial": 0, "passed": True, "score": 0.5 + x} for i, x in enumerate(d)]
    b = [{"task": f"t{i}", "trial": 0, "passed": True, "score": 0.5} for i in range(5)]
    r = compare.compare_arms(a, b, {**PAR, "min_tasks": 5})
    assert r["n_tasks"] == 5 and near(r["mean_diff"], 0.3, 1e-9)
    assert near(r["ci"][0], 0.3 - 2.7764 * 0.158114 / 5 ** 0.5, 1e-3) and near(r["ci"][1], 0.3 + 2.7764 * 0.158114 / 5 ** 0.5, 1e-3), r["ci"]
    assert r["decision"] == "better" and r["pass_k"] == {"a": None, "b": None}   # one trial a task: no pass^3 number
elif case == "better_worse":
    m = base(12, 3)
    hi, lo = [min(1.0, x + 0.2) for x in m], [max(0.0, x - 0.2) for x in m]
    assert compare.decide(arm(hi, noise=0.05, seed=1), arm(m, noise=0.05, seed=2), PAR) == "better"
    assert compare.decide(arm(lo, noise=0.05, seed=1), arm(m, noise=0.05, seed=2), PAR) == "worse"
elif case == "non_inferior":
    m = base(20, 5)
    a, b = arm([x - 0.01 for x in m], noise=0.03, seed=1), arm(m, noise=0.03, seed=2)
    assert compare.decide(a, b, PAR, cheaper=True) == "non_inferior"
    assert compare.decide(a, b, PAR) != "non_inferior"   # without the caller's cheaper claim, never non_inferior (here the small loss is real)
    assert compare.decide(a, b, {**PAR, "margin": 0.001}, cheaper=True) != "non_inferior"   # the margin is data
    c = arm([x - 0.2 for x in m], noise=0.03, seed=1)
    assert compare.decide(c, b, PAR, cheaper=True) == "worse"   # a loss beyond the margin is never excused by price
elif case == "noise":
    m = base(10, 7)
    assert compare.decide(arm(m, noise=0.3, seed=1), arm(m, noise=0.3, seed=2), PAR) == "inconclusive"
    acted = sum(compare.decide(arm(m, noise=0.3, seed=s), arm(m, noise=0.3, seed=s + 100), PAR) != "inconclusive" for s in range(40))
    assert acted <= 6, acted   # 5% false positives expected, never a flapping majority
elif case == "min_sample":
    r = compare.compare_arms(arm([0.9] * 7), arm([0.1] * 7), PAR)   # one below the minimum, however large the gap
    assert r["decision"] == "inconclusive" and r["reason"] == "min_sample", r
    assert compare.decide(arm([0.9] * 8), arm([0.1] * 8), PAR) == "better"
    # tasks only one arm ran are not paired: they do not count
    assert compare.compare_arms(arm([0.9] * 8), arm([0.1] * 7), PAR)["reason"] == "min_sample"
elif case == "regression":
    reg = [{"task": "t0", "source_card": "c1", "passing": True}, {"task": "t1", "source_card": "c2", "passing": True},
           {"task": "t2", "source_card": "c3", "passing": False}]
    good = arm([0.9] * 10, trials=2)
    assert compare.regression_ok(good, reg, PAR)["ok"] is True
    bad = [dict(r, passed=False, score=0.0) if (r["task"], r["trial"]) == ("t1", 1) else r for r in good]
    got = compare.regression_ok(bad, reg, PAR)
    assert got["ok"] is False and got["failed"] == ["t1"], got   # one failed trial of a set task fails it (min_pass_rate 1.0)
    assert compare.regression_ok(bad, reg, {**PAR, "regression_set": {"min_pass_rate": 0.5}})["ok"] is True   # the rule is data
    assert compare.regression_ok([r for r in good if r["task"] != "t0"], reg, PAR)["failed"] == ["t0"]   # not run = not passing
    assert compare.regression_ok([r for r in bad if r["task"] != "t2"], [reg[2]], PAR)["ok"] is True   # a task that never passed is not enforced
    b = arm([0.5] * 10, trials=2, noise=0.02, seed=4)
    r = compare.compare_arms(bad, b, PAR, regression=reg)
    assert r["decision"] == "worse" and r["reason"] == "regression_set" and r["failed"] == ["t1"], r   # better on average, still refused
    assert compare.compare_arms(good, b, PAR, regression=reg)["decision"] == "better"
elif case == "determinism":
    m = base(12, 11)
    a, b = arm(m, noise=0.1, seed=1), arm([x - 0.05 for x in m], noise=0.1, seed=2)
    r1 = compare.compare_arms(a, b, PAR, cheaper=True)
    rs = random.Random(5); a2, b2 = a[:], b[:]; rs.shuffle(a2); rs.shuffle(b2)
    assert json.dumps(r1, sort_keys=True) == json.dumps(compare.compare_arms(a, b, PAR, cheaper=True), sort_keys=True)
    assert json.dumps(r1, sort_keys=True) == json.dumps(compare.compare_arms(a2, b2, PAR, cheaper=True), sort_keys=True)
elif case == "stats":
    def rec(role, con, mod, task, passed, score, **k):
        return dict({"role": role, "connection": con, "model": mod, "task": task, "trial": 0, "passed": passed, "score": score,
                     "ts": "2026-11-01T00:00:00Z", "suite_version": "s1"}, **k)
    enough = [rec("r1", "c1", "m1", f"t{i}", True, 0.8) for i in range(5)]
    few = [rec("r1", "c2", "m2", f"t{i}", True, 0.9) for i in range(4)]
    prior = [{"role": "r1", "connection": "c1", "model": "m1", "score": 0.5}, {"role": "r1", "connection": "c2", "model": "m2", "score": 0.6},
             {"role": "r1", "connection": "c3", "model": "m3", "score": 0.7}]
    got = {(s["connection"]): s for s in compare.routing_stats(enough + few, prior, PAR)}
    assert got["c1"]["source"] == "benchmark" and near(got["c1"]["score"], 0.8, 1e-9) and got["c1"]["n"] == 5
    assert got["c2"]["source"] == "prior" and got["c2"]["score"] == 0.6 and got["c2"]["reason"] == "min_sample" and got["c2"]["n"] == 4
    assert got["c3"]["source"] == "prior" and got["c3"]["n"] == 0
    assert compare.routing_stats(few, [], PAR)[0]["score"] is None   # neither enough records nor a prior: no number
    # the newest suite version only: an older suite's records do not mix in
    old = [rec("r1", "c1", "m1", f"t{i}", False, 0.0, ts="2026-10-01T00:00:00Z", suite_version="s0") for i in range(5)]
    assert near([s for s in compare.routing_stats(enough + old, [], PAR) if s["connection"] == "c1"][0]["score"], 0.8, 1e-9)
    # tasks, not trials, are the sample: five trials of one task are one task
    one = [dict(rec("r1", "c9", "m9", "t0", True, 1.0), trial=i) for i in range(5)]
    assert compare.routing_stats(one, [], PAR)[0]["n"] == 1
elif case == "reader":
    row = {"role": "r1", "connection": "c1", "model": "m1", "task": "t0", "trial": 0, "passed": True, "score": 0.9,
           "ts": "2026-11-01T00:00:00Z", "suite_version": "s1"}
    path, iid = sys.argv[4], sys.argv[3]
    try:
        compare.record_results([dict(row, task="bad", score=7)])   # the writer refuses an invalid row and writes nothing
        raise SystemExit("an invalid row was accepted")
    except compare.Stop as x:
        assert x.code == "STL-MDL-753"
    assert compare.read_benchmarks() == ([], None)
    assert compare.record_results([row, dict(row, task="t4", cost=0.01)]) == 2
    assert sorted(r["task"] for r in compare.read_benchmarks()[0]) == ["t0", "t4"]
    doc = json.load(open(path))
    full = lambda **k: {**row, "install_id": iid, **k}
    doc["records"][0]["score"] = 0.1   # t0 edited by hand after its line was written
    doc["records"] += [full(task="t1", install_id="00000000-0000-4000-8000-000000000000"),   # another install
                       full(task="t2", score=7),   # invalid
                       full(task="t3")]   # valid but no trusted line
    json.dump(doc, open(path, "w"))
    recs, why = compare.read_benchmarks()
    assert sorted(r["task"] for r in recs) == ["t4"] and why is None, (recs, why)
    open(path, "w").write("{not json")
    recs, why = compare.read_benchmarks()
    assert recs == [] and why, (recs, why)
    import os; os.remove(path)
    assert compare.read_benchmarks() == ([], None)   # a missing file is a fresh install: no record, no problem
P

ok 'py tquant' "E1 the t quantile (no scipy) matches the tables for df 1, 2, 4, 9, 30, 1000 and another level"
ok 'py passk' "E2 pass^k is the chance that k trials drawn without replacement all pass, per task, averaged; none when no task has k trials"
ok 'py ci' "E3 paired differences: mean 0.3 and the 95% t-interval equal the hand calculation; pass^k reported per arm"
ok 'py better_worse' "E4 a planted gain is better and a planted loss is worse (paired, three trials a task)"
ok 'py non_inferior' "E5 a cheaper arm within the margin is non_inferior; not cheaper, a margin that is too tight, are inconclusive; a loss beyond the margin is worse"
ok 'py noise' "E6 pure noise is inconclusive (one planted case, and few false positives over 40 seeds)"
ok 'py min_sample' "E7 fewer paired tasks than min_tasks is inconclusive with reason min_sample; unpaired tasks do not count"
ok 'py regression' "E8 a failing regression-set task refuses (worse, reason regression_set) whatever the mean; the rule, missing tasks and unfixed tasks"
ok 'py determinism' "E9 same input, same output, whatever the record order"
ok 'py stats' "E10 routing_stats: the prior below the minimum sample (with the reason), the benchmark mean above; newest suite only; tasks are the sample"
ok 'py reader "$IID" "$BF"' "E11 the benchmark reader accepts only records with a trusted line: foreign-install, invalid, unproved and hand-edited records are ignored, an unreadable file fails closed"

# ---- the CLI, the fake entry, the data ----
mk() { python3 -I -c "
import json, sys
n, base, gap, noise = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
import random; rg = random.Random(8)
a, b = [], []
for t in range(n):
    m = base + rg.uniform(-0.2, 0.2)
    for k in range(3):
        a.append({'task': 't%d' % t, 'trial': k, 'passed': True, 'score': min(1, max(0, m + gap + rg.uniform(-noise, noise)))})
        b.append({'task': 't%d' % t, 'trial': k, 'passed': True, 'score': min(1, max(0, m + rg.uniform(-noise, noise)))})
json.dump(a, open('$T/a.json', 'w')); json.dump(b, open('$T/b.json', 'w'))" "$@"; }
mk 20 0.6 -0.01 0.03
ok 'cp_ compare --a "$T/a.json" --b "$T/b.json" --cheaper --json | jq -e ".decision == \"non_inferior\" and .n_tasks == 20 and (.ci | length) == 2"' \
  "E12 CLI compare: one JSON answer with the decision, the task count and the interval, exit 0"
ok '[ "$(cp_ compare --a "$T/a.json" --b "$T/b.json" --json | jq -r .decision)" = inconclusive ]' "E13 the same files without --cheaper are inconclusive"
ed model-check.json '.margin = 0.001'
ok '[ "$(cp_ compare --a "$T/a.json" --b "$T/b.json" --cheaper --json | jq -r .decision)" = inconclusive ]' "E14 the margin is read from model-check.json: a tighter margin flips the decision, no code change"
ed model-check.json '.margin = 0.05 | .min_tasks = 30'
ok '[ "$(cp_ compare --a "$T/a.json" --b "$T/b.json" --cheaper --json | jq -r .reason)" = min_sample ]' "E15 min_tasks is data too: 30 makes 20 tasks min_sample"
ed model-check.json '.min_tasks = 8'
jq -c '[.[] | select(.task == "t1" and .trial == 0) | .passed = false] + [.[] | select(.task != "t1" or .trial != 0)]' "$T/a.json" >"$T/a2.json"
printf '[{"task":"t1","source_card":"c9","passing":true}]' >"$T/reg.json"
cp_ compare --a "$T/a2.json" --b "$T/b.json" --regression "$T/reg.json" --json >"$T/out"; rc=$?
ok '[ "$rc" = 1 ] && jq -e ".decision == \"worse\" and .reason == \"regression_set\" and .code == \"STL-MDL-751\"" "$T/out" && grep -q STL-MDL-751 "$T/err"' \
  "E16 CLI compare refuses a regression-set failure: exit 1, STL-MDL-751, decision worse"
echo '{' >"$T/bad.json"
cp_ compare --a "$T/bad.json" --b "$T/b.json" --json >"$T/out"; rc=$?
ok '[ "$rc" = 1 ] && grep -q STL-MDL-750 "$T/err" && jq -e ".code == \"STL-MDL-750\"" "$T/out"' "E17 an unreadable or invalid input is refused: exit 1, STL-MDL-750"

# the fake entry: a role, a connection and a model no file of the stack names, only in a scratch benchmark file
python3 -I -c "
import json
json.dump([{'role': 'zz-role', 'connection': 'zz-conn', 'model': 'zz-model', 'task': 't%d' % i, 'trial': 0, 'passed': i % 2 == 0, 'score': 0.5,
            'ts': '2026-11-01T00:00:00Z', 'suite_version': 'v9'} for i in range(8)], open('$T/rows.json', 'w'))"
ok 'cp_ record --file "$T/rows.json" --json | jq -e ".recorded == 8" && grep -c benchmark.recorded "$R/$(ix .event_log)"' "E17b record writes the records and their trusted line (host)"
ok 'STUB_WORKER_MARK=1 python3 -I -B "$R/bin/compare.py" record --file "$T/rows.json" 2>/dev/null; [ $? = 1 ]' "E17c record in a worker environment is refused" 
printf '[{"role":"zz-role","connection":"zz-conn","model":"zz-model","score":0.9}]' >"$T/prior.json"
ok 'cp_ stats --prior "$T/prior.json" --json | jq -e "length == 1 and .[0].source == \"benchmark\" and .[0].score == 0.5 and .[0].role == \"zz-role\""' \
  "E18 fake entry: a new role, connection and model in a benchmark file is used by stats with no code change"
ed model-check.json '.routing_min_tasks = 9'
ok 'cp_ stats --prior "$T/prior.json" --json | jq -e ".[0].source == \"prior\" and .[0].score == 0.9 and .[0].reason == \"min_sample\""' \
  "E19 routing_min_tasks is data: raised above the sample, the advertised score stands, with the reason"
ed model-check.json '.routing_min_tasks = 5'
echo '{' >"$BF"
ok 'cp_ stats --prior "$T/prior.json" --json | jq -e ".[0].source == \"prior\" and .[0].score == 0.9" && cp_ check --json | jq -e ".ok == false" ; [ "$(cp_ check --json >/dev/null; echo $?)" = 1 ] && grep -q STL-MDL-753 "$T/err"' \
  "E20 an unreadable benchmark file fails closed: stats falls back to the prior, check says so (exit 1, STL-MDL-753)"
rm -f "$BF"
ok 'cp_ check --json | jq -e ".ok == true"' "E21 check passes on the shipped model-check.json"
ed model-check.json '.confidence = 1.5'
ok '[ "$(cp_ check --json >/dev/null; echo $?)" = 1 ] && grep -q STL-MDL-752 "$T/err"' "E22 an invalid model-check.json is refused by check (STL-MDL-752) and by compare"
ok '[ "$(cp_ compare --a "$T/a.json" --b "$T/b.json" --json >/dev/null; echo $?)" = 1 ] && grep -q STL-MDL-752 "$T/err"' "E23 compare refuses to run on invalid parameters (STL-MDL-752)"
ed model-check.json '.confidence = 0.95 | .pass_k = 9'
ok '[ "$(cp_ check --json >/dev/null; echo $?)" = 1 ] && grep -q STL-MDL-752 "$T/err"' "E24 pass_k above the trial count is refused (STL-MDL-752)"
ed model-check.json '.pass_k = 3'
ok 'python3 -I -B "$R/bin/stella_data.py" check' "E25 the data index judges model-check.json (schema model-check) and the benchmark_results key"

# ---- HC1 item 8: the chunk of digests per event line and the read cap are data (model-check.json) ----
ed model-check.json '.pass_k = 3 | .event_chunk = 3'
EV=$R/$(ix .event_log); n0=$(grep -c '"benchmark.recorded"' "$EV")
cp_ record --file "$T/rows.json" --json >/dev/null
ok '[ "$(grep -c "\"benchmark.recorded\"" "$EV")" = "$((n0 + 3))" ]' "E26 event_chunk is data: 8 records with a chunk of 3 are three trusted lines, no code change"
ed model-check.json '.read_cap_bytes = 1024'
ok '[ "$(cp_ compare --a "$T/a.json" --b "$T/b.json" --json >/dev/null; echo $?)" = 1 ] && grep -q STL-MDL-750 "$T/err"' "E27 read_cap_bytes is data: a file above the cap is refused (STL-MDL-750)"
ed model-check.json '.read_cap_bytes = 8388608 | .event_chunk = 100'
ok 'cp_ compare --a "$T/a.json" --b "$T/b.json" --json | jq -e ".decision"' "E28 the shipped cap reads the same files"

echo "# compare-selftest: $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
