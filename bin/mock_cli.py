#!/usr/bin/env python3
"""Fake coding CLI for tests (F2 test rig): stands in for a cli-login connection. Reads a prompt on stdin, prints a result JSON.
MOCK_CLI_MODE: ok (default) | usage_limit | timeout | model_gone. MOCK_CLI_SECONDS: how long timeout hangs (default 60).
MOCK_CLI_USAGE: a number; every mode then first prints the usage block "plan usage: <n>% of your limit used" on stderr (the plan share a cli-login CLI shows).
MOCK_CLI_CALLS: a file that gets one JSON line per invocation, written at start: {"argv": [...], "env": [names only]}.
Any argument is accepted; --model <id> names the model in the model_gone message."""
import json, os, sys, time

argv = sys.argv[1:]
calls = os.environ.get("MOCK_CLI_CALLS")
if calls:
    with open(calls, "a") as f:
        f.write(json.dumps({"argv": argv, "env": sorted(os.environ)}) + "\n")
mode = os.environ.get("MOCK_CLI_MODE") or "ok"
prompt = sys.stdin.read()
model = argv[argv.index("--model") + 1] if "--model" in argv and argv.index("--model") + 1 < len(argv) else "unknown"
if os.environ.get("MOCK_CLI_USAGE"):
    print(f"plan usage: {os.environ['MOCK_CLI_USAGE']}% of your limit used", file=sys.stderr)
if mode == "usage_limit":
    print("usage limit reached for this plan; try again later", file=sys.stderr)
    sys.exit(1)
if mode == "model_gone":
    print(f"model {model} was not found", file=sys.stderr)
    sys.exit(1)
if mode == "timeout":
    time.sleep(float(os.environ.get("MOCK_CLI_SECONDS") or 60))
    sys.exit(1)
if mode != "ok":
    print(f"unknown mode {mode}", file=sys.stderr)
    sys.exit(2)
print(json.dumps({"result": f"ok: {len(prompt)} chars", "model": model}))
