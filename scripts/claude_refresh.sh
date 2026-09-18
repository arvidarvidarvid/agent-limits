#!/bin/bash
# Test whether the (orphaned) keychain refresh token can mint a fresh,
# profile-scoped access token, then call the usage endpoint with it.
#
# On success this also seeds ~/.config/agent-limits/config.json with the rotated
# tokens so the app can take over. Refresh tokens rotate on use, so the new one
# is saved immediately; the old one in the keychain becomes single-use spent.
# This only touches the keychain entry the live Claude session no longer uses.
#
# Run it yourself: ./scripts/claude_refresh.sh
set -uo pipefail

CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL="https://platform.claude.com/v1/oauth/token"
CONFIG="$HOME/.config/agent-limits/config.json"

# There can be several "Claude Code-credentials" entries (keyed by unix username
# vs email); the native build keeps the username one fresher. Read the
# username-scoped entry and the default one, and keep whichever has the highest
# expiresAt, whose refresh token is most likely still live.
KEYCHAIN_JSON=""
BEST_EXP=-1
for BLOB in \
  "$(security find-generic-password -a "$(id -un)" -s "Claude Code-credentials" -w 2>/dev/null)" \
  "$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)"; do
  [[ -n "$BLOB" ]] || continue
  EXP=$(BLOB="$BLOB" python3 -c 'import os,json;d=json.loads(os.environ["BLOB"]);o=d.get("claudeAiOauth",d);print(int(o.get("expiresAt") or 0))' 2>/dev/null || echo 0)
  if [[ "$EXP" -gt "$BEST_EXP" ]]; then BEST_EXP="$EXP"; KEYCHAIN_JSON="$BLOB"; fi
done
if [[ -z "${KEYCHAIN_JSON:-}" ]]; then
  echo "no keychain entry found; nothing to refresh"
  exit 1
fi

export KEYCHAIN_JSON CLIENT_ID TOKEN_URL CONFIG
python3 - <<'PY'
import json, os, urllib.request, datetime as dt

blob = json.loads(os.environ["KEYCHAIN_JSON"])["claudeAiOauth"]
refresh = blob.get("refreshToken")
if not refresh:
    print("keychain entry has no refreshToken"); raise SystemExit(1)

body = json.dumps({
    "grant_type": "refresh_token",
    "refresh_token": refresh,
    "client_id": os.environ["CLIENT_ID"],
}).encode()
# platform.claude.com is behind Cloudflare. Python-urllib's UA gets a 1010
# "banned browser signature", and a browser-like UA gets 429; a plain app
# name/version passes (per PanithanNanti/claude-usage-widget, which does this).
UA = "agent-limits/0.1"
req = urllib.request.Request(os.environ["TOKEN_URL"], data=body, headers={
    "Content-Type": "application/json",
    "User-Agent": UA,
    "Accept": "application/json",
})
try:
    resp = json.loads(urllib.request.urlopen(req).read().decode())
except urllib.error.HTTPError as e:
    print(f"refresh failed: HTTP {e.code}")
    print("  " + e.read().decode()[:400]); raise SystemExit(1)

access = resp.get("access_token")
new_refresh = resp.get("refresh_token", refresh)
expires_in = resp.get("expires_in", 0)
scope = resp.get("scope", "")
print("refresh OK")
print("  scope:", scope or "(not returned)")
print("  access token:", (access[:14] + "...") if access else "(none)")
print("  expires_in:", expires_in, "s ->",
      (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=expires_in)).isoformat())

# Seed the app config with the rotated tokens (preserve any existing fields).
cfg = {}
try:
    cfg = json.load(open(os.environ["CONFIG"]))
except Exception:
    pass
cfg.pop("claudeToken", None)  # drop the inference-only setup-token
cfg["claudeAccessToken"] = access
cfg["claudeRefreshToken"] = new_refresh
cfg["claudeExpiresAt"] = int((dt.datetime.now(dt.timezone.utc).timestamp() + expires_in) * 1000)
os.makedirs(os.path.dirname(os.environ["CONFIG"]), exist_ok=True)
with open(os.environ["CONFIG"], "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(os.environ["CONFIG"], 0o600)
print("  saved rotated tokens to", os.environ["CONFIG"])

# Now call the usage endpoint with the fresh, profile-scoped access token.
print("\n=== GET /api/oauth/usage with refreshed token ===")
ureq = urllib.request.Request("https://api.anthropic.com/api/oauth/usage", headers={
    "Authorization": "Bearer " + access,
    "anthropic-beta": "oauth-2025-04-20",
    "anthropic-version": "2023-06-01",
    "User-Agent": UA,
})
try:
    print(json.dumps(json.loads(urllib.request.urlopen(ureq).read().decode()), indent=2))
except urllib.error.HTTPError as e:
    print(f"usage request failed: HTTP {e.code}")
    print("  " + e.read().decode()[:400])
PY
