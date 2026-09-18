#!/bin/bash
# Print the raw usage JSON from Claude and Codex so the decoders can be matched
# to the real field names. Reads your existing OAuth tokens; sends nothing but
# the usage GET requests. Run it yourself: `./scripts/probe.sh`
set -uo pipefail

echo "=== Claude: GET /api/oauth/usage (keychain token) ==="
# The usage endpoint needs the user:profile scope, which the subscription login
# token in the keychain has (setup-token does not). Read from the keychain and
# report the token's freshness + scopes so we can see if a re-login refreshed it.
KEYCHAIN_JSON=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
if [[ -z "${KEYCHAIN_JSON:-}" ]]; then
  echo "  (no keychain entry; run \`claude auth login\`)"
else
  echo "$KEYCHAIN_JSON" | python3 -c "
import sys, json, datetime as dt
d = json.load(sys.stdin)['claudeAiOauth']
exp = d.get('expiresAt', 0)/1000
when = dt.datetime.fromtimestamp(exp, dt.timezone.utc).isoformat() if exp else '?'
fresh = 'FRESH' if exp and dt.datetime.now(dt.timezone.utc).timestamp() < exp else 'EXPIRED'
print(f'  token expiresAt: {when}  [{fresh}]')
print('  scopes:', ' '.join(d.get('scopes', [])))
print('  has user:profile:', 'user:profile' in d.get('scopes', []))
"
  CLAUDE_TOKEN=$(echo "$KEYCHAIN_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
  echo "  --- response ---"
  curl -sS https://api.anthropic.com/api/oauth/usage \
    -H "Authorization: Bearer $CLAUDE_TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "anthropic-version: 2023-06-01" | python3 -m json.tool 2>/dev/null || echo "  (request failed)"
fi

echo
echo "=== Codex: GET /backend-api/wham/usage ==="
python3 - <<'PY'
import json, urllib.request, os
path = os.path.expanduser("~/.codex/auth.json")
try:
    a = json.load(open(path))
    t = a["tokens"]["access_token"]
    acc = a["tokens"].get("account_id", "") or ""
except Exception as e:
    print(f"  (no Codex auth.json, run `codex` and log in)  [{e}]")
    raise SystemExit
req = urllib.request.Request(
    "https://chatgpt.com/backend-api/wham/usage",
    headers={"Authorization": "Bearer " + t, "chatgpt-account-id": acc},
)
try:
    body = urllib.request.urlopen(req).read().decode()
    print(json.dumps(json.loads(body), indent=2))
except Exception as e:
    print(f"  (request failed: {e})")
PY
