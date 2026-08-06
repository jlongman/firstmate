#!/usr/bin/env bash
# Portable test for bin/fm-gh-app-token.sh: the fail-closed contract (usage errors
# and a missing GitHub App), which needs no network or real App. The happy path
# (actually minting an installation token) is a live/integration check, exercised
# by the maintainer's live vend proof, not here.
set -u
FM=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$FM/bin/fm-gh-app-token.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-ghtok.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi; }

# usage: no repo argument -> exit 2, nothing on stdout
rc=0; out=$("$TOOL" 2>/dev/null) || rc=$?
eq "$rc" 2 "missing repo arg exits 2"
if [ -z "$out" ]; then pass "no stdout on usage error"; else fail "usage error emitted stdout"; fi

# a non owner/repo argument -> exit 2
rc=0; "$TOOL" notaslug >/dev/null 2>&1 || rc=$?
eq "$rc" 2 "non owner/repo arg exits 2"

# no GitHub App configured (empty FM_ROOT) -> fail CLOSED (exit 3), clear message,
# and crucially NO token on stdout (never push unauthenticated).
rc=0; out=$(FM_ROOT_OVERRIDE="$TMP" "$TOOL" mavtek/example 2>/dev/null) || rc=$?
eq "$rc" 3 "no App configured -> fail closed (exit 3)"
if [ -z "$out" ]; then pass "no token on stdout when unconfigured"; else fail "emitted a token with no App configured"; fi
err=$(FM_ROOT_OVERRIDE="$TMP" "$TOOL" mavtek/example 2>&1 >/dev/null)
case "$err" in
  *"no GitHub App configured"*) pass "unconfigured message is actionable" ;;
  *) fail "unclear unconfigured message: $err" ;;
esac

if [ "$fails" -eq 0 ]; then echo "PASS: fm-gh-app-token"; else echo "FAIL: fm-gh-app-token ($fails)"; exit 1; fi
