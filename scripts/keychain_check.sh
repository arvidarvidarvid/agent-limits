#!/bin/bash
# Report every Claude Code keychain entry we can find, with freshness and scopes.
# Values are masked; this only prints expiry and scope metadata.
# Run it yourself: bash scripts/keychain_check.sh
set -u

report() {  # $1 = blob json
  python3 -c '
import sys, json, datetime as dt
try:
    d = json.load(sys.stdin)
except Exception:
    print("  (unparseable)"); sys.exit(0)
o = d.get("claudeAiOauth", d) if isinstance(d, dict) else {}
e = (o.get("expiresAt") or 0) / 1000
now = dt.datetime.now(dt.timezone.utc).timestamp()
when = dt.datetime.fromtimestamp(e, dt.timezone.utc).isoformat() if e else "?"
state = "FRESH" if e > now else "EXPIRED"
print(f"  expiresAt {when} [{state}]")
print("  scopes:", " ".join(o.get("scopes", [])) or "(none)")
print("  has refreshToken:", bool(o.get("refreshToken")))
' <<< "$1"
}

for svc in "Claude Code-credentials" "Claude Code"; do
  for acct in "$(id -un)"; do
    echo "service='$svc' account='$acct':"
    BLOB=$(security find-generic-password -a "$acct" -s "$svc" -w 2>/dev/null)
    if [[ -n "${BLOB:-}" ]]; then report "$BLOB"; else echo "  (no such entry)"; fi
  done
  echo "service='$svc' (any account):"
  BLOB=$(security find-generic-password -s "$svc" -w 2>/dev/null)
  if [[ -n "${BLOB:-}" ]]; then report "$BLOB"; else echo "  (no such entry)"; fi
done

echo
echo "--- ~/.claude/.credentials.json ---"
if [[ -f "$HOME/.claude/.credentials.json" ]]; then
  report "$(cat "$HOME/.claude/.credentials.json")"
else
  echo "  (absent)"
fi
