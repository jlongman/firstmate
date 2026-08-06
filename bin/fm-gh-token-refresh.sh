#!/usr/bin/env bash
# fm-gh-token-refresh.sh - re-mint aging vended GitHub push tokens for confined
# tasks so a long-running crewmate's ~1h token never expires mid-task.
#
# Called from the watcher's CHECK_INTERVAL sweep (bin/fm-watch.sh); it rides the
# existing supervision loop rather than a per-task background process. Best-effort
# and FAIL-SAFE: a per-task problem is warned and skipped, never fatal, so a token
# hiccup can never take the watcher down.
#
# For each state/<id>.meta carrying gh_vend_repo= (written only for an srt-confined
# claude crewmate when a GitHub App is configured), if the worktree still holds the
# vended credential and it is older than the refresh threshold, re-mint via
# fm-gh-app-token.sh and rewrite the store file the crewmate's git reads. No App /
# no confined vend => the loop finds nothing and does nothing.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE=${FM_STATE_OVERRIDE:-$FM_ROOT/state}
REFRESH_AFTER=${FM_GH_TOKEN_REFRESH_AFTER:-2400}   # re-mint when the cred is older than ~40min

now=$(date +%s)
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  repo=$(sed -n 's/^gh_vend_repo=//p' "$meta" | head -1)
  [ -n "$repo" ] || continue
  wt=$(sed -n 's/^worktree=//p' "$meta" | head -1)
  cred="$wt/.git-credentials"
  [ -n "$wt" ] && [ -f "$wt/.fm-gitconfig" ] && [ -f "$cred" ] || continue

  mtime=$(stat -f %m "$cred" 2>/dev/null || stat -c %Y "$cred" 2>/dev/null || echo 0)
  [ "$((now - mtime))" -ge "$REFRESH_AFTER" ] || continue

  if tok=$("$FM_ROOT/bin/fm-gh-app-token.sh" "$repo" 2>/dev/null) && [ -n "$tok" ]; then
    ( umask 077; printf 'https://x-access-token:%s@github.com\n' "$tok" > "$cred" )
    unset tok
  else
    echo "fm-gh-token-refresh: re-mint failed for $repo ($(basename "$meta" .meta)); the worker's push token may expire" >&2
  fi
done
