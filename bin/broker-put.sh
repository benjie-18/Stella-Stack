#!/usr/bin/env bash
# Store one secret in the stand-in broker folder (follow-up 4, owner decision: a Claude profile's long-lived token goes through the broker).
# usage: bin/broker-put.sh <name>      the secret is read from the terminal without echo (or from stdin when it is not a terminal);
#                                      it is written to <hermes root>/broker/<name> with mode 0600 and shown nowhere.
# For that token: in your own terminal run `claude setup-token`, copy the token it prints, then `bin/broker-put.sh <the name in roles.json broker_env>`
# and paste it. Name rules and token rules are the same as bin/box.py _broker (a-z0-9_.- names; 16-4096 characters of A-Za-z0-9_.~+/=-).
set -eu
name=${1:-}
[[ $name =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ && $name != *..* ]] || { echo "usage: broker-put.sh <name>   (name: a-z0-9_.-, no ..)" >&2; exit 2; }
root=${HERMES_ROOT:-$HOME/.hermes}
if [ -t 0 ]; then read -rsp "Secret for $name (not shown): " val; echo >&2; else IFS= read -r val || true; fi
[[ $val =~ ^[A-Za-z0-9_.~+/=-]{16,4096}$ ]] || { echo "that does not look like a token (16-4096 characters of A-Za-z0-9_.~+/=-); nothing was stored" >&2; exit 1; }
umask 077
mkdir -p "$root/broker"; chmod 700 "$root/broker"
tmp=$(mktemp "$root/broker/.put.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf '%s' "$val" >"$tmp"
mv -fT "$tmp" "$root/broker/$name"
chmod 600 "$root/broker/$name"
echo "stored $name in $root/broker (mode 600); the next review run uses it" >&2
