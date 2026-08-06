#!/usr/bin/env bash
# fm-gh-app-token.sh - mint a short-lived, repo-scoped GitHub token for a crewmate.
#
# Prints a GitHub App installation access token (ghs_...) on stdout, scoped to a
# SINGLE repo with contents/pull_requests/workflows write, expiring in ~1h. This
# lets an srt-confined crewmate push over HTTPS without ever seeing the captain's
# stored GitHub credentials (~/.config/gh and ~/.ssh stay denied by the sandbox).
#
# Auth source (both LOCAL, gitignored under config/; firstmate reads them only here):
#   config/gh-app-id   - the numeric GitHub App ID
#   config/gh-app.pem  - the App's private key (never printed, never committed)
# The App must be installed on the target repo; its granted permissions are the
# hard ceiling on any minted token.
#
# Usage:  fm-gh-app-token.sh <owner/repo>
# Exit:   0 + token on stdout; nonzero + reason on stderr (fail closed - callers
#         that require a push token must treat a failure as a blocker, never push
#         unauthenticated). Prints nothing on stdout on failure.
#
# Mechanics owner: this header + the code below. Requires openssl, curl, python3.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
ID_FILE="$FM_ROOT/config/gh-app-id"
KEY_FILE="$FM_ROOT/config/gh-app.pem"
API=${FM_GH_API:-https://api.github.com}

repo=${1:-}
case "$repo" in
  */*) : ;;
  *) echo "fm-gh-app-token: usage: fm-gh-app-token.sh <owner/repo>" >&2; exit 2 ;;
esac
owner=${repo%%/*}; name=${repo##*/}

[ -f "$ID_FILE" ] && [ -f "$KEY_FILE" ] || {
  echo "fm-gh-app-token: no GitHub App configured (need config/gh-app-id and config/gh-app.pem)" >&2
  exit 3
}
app_id=$(tr -d '[:space:]' < "$ID_FILE")
[ -n "$app_id" ] || { echo "fm-gh-app-token: config/gh-app-id is empty" >&2; exit 3; }

for t in openssl curl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "fm-gh-app-token: missing required tool: $t" >&2; exit 4; }
done

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jget() { python3 -c 'import sys,json;
try:
 d=json.load(sys.stdin)
except Exception:
 sys.exit(1)
v=d
for k in sys.argv[1].split("."):
 v=v.get(k) if isinstance(v,dict) else None
print(v if v is not None else "")' "$1" 2>/dev/null || true; }

now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$app_id" | b64url)
sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$KEY_FILE" -binary 2>/dev/null | b64url) || {
  echo "fm-gh-app-token: could not sign JWT (bad or unreadable private key?)" >&2; exit 5; }
jwt="$header.$payload.$sig"

inst_json=$(curl -sS --max-time 20 -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" "$API/repos/$owner/$name/installation" 2>/dev/null) || {
  echo "fm-gh-app-token: installation lookup failed for $repo (network?)" >&2; exit 6; }
inst_id=$(printf '%s' "$inst_json" | jget id)
[ -n "$inst_id" ] || {
  echo "fm-gh-app-token: no App installation on $repo (install the App on this repo)" >&2; exit 6; }

tok_json=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  "$API/app/installations/$inst_id/access_tokens" \
  -d "{\"repositories\":[\"$name\"],\"permissions\":{\"contents\":\"write\",\"pull_requests\":\"write\",\"workflows\":\"write\"}}" 2>/dev/null) || {
  echo "fm-gh-app-token: token mint request failed for $repo" >&2; exit 7; }
token=$(printf '%s' "$tok_json" | jget token)
[ -n "$token" ] || {
  msg=$(printf '%s' "$tok_json" | jget message)
  echo "fm-gh-app-token: mint returned no token for $repo${msg:+ ($msg)}" >&2; exit 7; }

printf '%s\n' "$token"
