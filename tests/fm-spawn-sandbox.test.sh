#!/usr/bin/env bash
# Test: user-configurable crewmate OS confinement via srt (docs/crewmate-sandbox.md).
#
# Guards the two launch paths fm-spawn.sh builds for a claude crewmate and the
# per-task srt-settings.json the sandbox policy owner emits:
#   - srt OFF (default; config/crew-sandbox absent or "off"): the plain launch,
#     byte-identical to before this change - claude --dangerously-skip-permissions
#     with the unchanged __OPINPUT__ brief-passing, no srt, no env scrub.
#   - srt ON (config/crew-sandbox = srt|on|auto): the launch wrapped in
#     `env -u <secrets> srt --settings <file> ... claude --dangerously-skip-permissions`,
#     plus a correct srt-settings.json (network allowlist, denyRead, allowWrite with
#     the resolved absolute git-common-dir and a SINGLE-file turn-end allow, and a
#     denyWrite that re-blocks the parent .git/config and hooks).
#
# This asserts the config is GENERATED correctly. It CANNOT assert the OS sandbox
# ENFORCES it - that needs a live Seatbelt/bubblewrap probe on a real host (see
# docs/crewmate-sandbox.md "Verifying enforcement" and the smoke check in
# bin/fm-check-sandbox-policy.sh preflight). srt is not required to run this test.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPAWN="$FM_ROOT/bin/fm-spawn.sh"
POLICY="$FM_ROOT/bin/fm-check-sandbox-policy.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

[ -f "$SPAWN" ] || fail "bin/fm-spawn.sh not found at $SPAWN"
[ -x "$POLICY" ] || fail "bin/fm-check-sandbox-policy.sh not found or not executable at $POLICY"

# ---------------------------------------------------------------------------
# 1. LAUNCH TEMPLATES: extract launch_template() and exercise both paths.
# ---------------------------------------------------------------------------
# The function is self-contained (printf + case, no globals), so eval it in
# isolation rather than driving the full fm-spawn.sh preamble (which needs a live
# backend). This directly proves off vs on without a live session.
fn=$(awk '/^launch_template\(\) \{/{f=1} f{print} f&&/^\}/{c++} c>0{exit}' "$SPAWN")
[ -n "$fn" ] || fail "could not extract launch_template() from fm-spawn.sh"
eval "$fn"

plain=$(launch_template claude ship 0)
srt=$(launch_template claude ship 1)
deflt=$(launch_template claude ship)

# OFF path is exactly today's plain launch.
case "$plain" in
  *"claude --dangerously-skip-permissions"*) : ;;
  *) fail "srt-off claude launch dropped --dangerously-skip-permissions (must stay: it is the OFF-path autonomy mechanism)" ;;
esac
case "$plain" in
  *srt*) fail "srt-off claude launch must NOT reference srt" ;;
  *"env -u"*) fail "srt-off claude launch must NOT scrub env (byte-identical to before)" ;;
  *'__OPINPUT__ encode launch-brief < __BRIEF__'*) pass "srt-off launch keeps the existing __OPINPUT__ brief-passing" ;;
  *) fail "srt-off claude launch lost the __OPINPUT__ brief-passing" ;;
esac

# The default (no third arg) must equal the OFF path: existing 2-arg callers are
# unchanged, so a non-adopter fleet is completely unaffected.
[ "$deflt" = "$plain" ] || fail "launch_template default (2-arg) must equal the srt-off launch; got a different string"
pass "srt-off launch is byte-identical to the 2-arg default (non-adopters unaffected)"

# ON path: the exact env -u scrub list, the srt wrap, the flag STAYS, brief-passing unchanged.
for tok in \
  "env -u ANTHROPIC_API_KEY" "-u GITHUB_TOKEN" "-u GH_TOKEN" \
  "-u AWS_ACCESS_KEY_ID" "-u AWS_SECRET_ACCESS_KEY" "-u AWS_SESSION_TOKEN" \
  "__SRTCMD__ --settings __SRTSETTINGS__" \
  "claude --dangerously-skip-permissions" \
  '__OPINPUT__ encode launch-brief < __BRIEF__'
do
  case "$srt" in
    *"$tok"*) : ;;
    *) fail "srt-on claude launch is missing required token: $tok" ;;
  esac
done
pass "srt-on launch scrubs all six secret vars, wraps in srt --settings, keeps --dangerously-skip-permissions and the brief-passing"

# The scrub must run OUTSIDE the wall: env -u ... must precede __SRTCMD__.
case "$srt" in
  *"env -u ANTHROPIC_API_KEY"*"__SRTCMD__ --settings"*) pass "env scrub runs outside srt (srt does not scrub env itself)" ;;
  *) fail "srt-on launch must scrub env BEFORE the srt invocation" ;;
esac

# ---------------------------------------------------------------------------
# 2. CONFIG-MODE WIRING (static invariants on fm-spawn.sh source).
# ---------------------------------------------------------------------------
src=$(cat "$SPAWN")
need() { case "$src" in *"$1"*) pass "$2" ;; *) fail "$2 (missing: $1)" ;; esac; }

need 'config/crew-sandbox'                 "reads the config/crew-sandbox knob"
need 'on|srt) CREW_SANDBOX_MODE=srt'       "on and srt both select the srt mode"
need 'auto)   CREW_SANDBOX_MODE=auto'      "auto mode is accepted"
need "''|off) CREW_SANDBOX_MODE=off"       "absent/off maps to off (the default)"
need 'SANDBOX_ACTIVE=1'                    "SANDBOX_ACTIVE is the single gate for the srt path"
need 'emit-settings'                       "srt-settings.json is generated from the policy owner"
need 'exclude_path '\''srt-settings.json'\''' "srt-settings.json is git-excluded like other generated worktree files"
# shellcheck disable=SC2016  # matching literal source text; $ must stay unexpanded
need 'echo "sandbox=$SANDBOX_META"'        "meta records sandbox=on|off"
need 'codeartifact'                        "CodeArtifact token vend is present"

# The vend must never write a live token into a git-tracked .npmrc: guard on the
# path being untracked, warn-and-skip when tracked, and only write+exclude when not.
need 'ls-files --error-unmatch .npmrc'     "CodeArtifact vend guards on .npmrc being untracked"
case "$src" in
  *'ls-files --error-unmatch .npmrc'*'refusing to vend a CodeArtifact token into a tracked file'*)
    pass "tracked .npmrc: vend refuses and warns (no token written, no exclude_path)" ;;
  *) fail "tracked .npmrc must be skipped with a warning, never overwritten with a token" ;;
esac
# The write + exclude only happen in the untracked branch (after the ls-files guard),
# so a tracked, committed .npmrc is never left dirty with a live token.
case "$src" in
  *'ls-files --error-unmatch .npmrc'*'} > "$WT/.npmrc"'*'exclude_path '\''.npmrc'\'''*)
    pass "untracked .npmrc: token is written and git-excluded" ;;
  *) fail "untracked .npmrc write + exclude_path must follow the ls-files untracked guard" ;;
esac

# srt/on must REFUSE the spawn on a failed preflight; auto must fall back with a warning.
case "$src" in
  *'config/crew-sandbox=srt but the srt preflight failed'*'refusing to launch unconfined'*)
    pass "srt/on refuses the spawn (exits) when the preflight fails" ;;
  *) fail "srt/on must refuse the spawn on preflight failure, not fall back silently" ;;
esac
case "$src" in
  *'config/crew-sandbox=auto but the srt preflight failed'*'launching unconfined'*)
    pass "auto falls back to a plain launch with a loud warning on preflight failure" ;;
  *) fail "auto must warn and fall back to a plain launch on preflight failure" ;;
esac

# The turn-end Stop hook is unchanged and stays a SINGLE-file allow (never the whole state dir).
# shellcheck disable=SC2016  # matching literal source text; $TURNEND must stay unexpanded
case "$src" in
  *'"command":"touch '"'"'$TURNEND'"'"'"'*) pass "turn-end Stop hook is unchanged (touches the single turn-ended file)" ;;
  *) fail "turn-end Stop hook must be preserved unchanged" ;;
esac

# The srt-settings generation and the vend are gated on SANDBOX_ACTIVE, so the OFF
# path never writes srt-settings.json or a vended .npmrc.
# shellcheck disable=SC2016  # matching literal source text; $SANDBOX_ACTIVE must stay unexpanded
case "$src" in
  *'if [ "$SANDBOX_ACTIVE" = 1 ]; then'*'emit-settings'*) pass "srt-settings + vend are gated behind SANDBOX_ACTIVE (OFF path writes neither)" ;;
  *) fail "srt-settings/vend must be gated on SANDBOX_ACTIVE" ;;
esac

# ---------------------------------------------------------------------------
# 3. srt-settings.json SHAPE (dynamic, via the policy owner). No srt needed.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-sandbox.XXXXXX"); trap 'rm -rf "$TMP"' EXIT

# A LINKED worktree so we prove the git-common-dir resolves to the MAIN repo's .git
# (the security-critical property; a per-worktree .git would miss the parent config).
git -C "$TMP" init -q main
git -C "$TMP/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$TMP/main" worktree add -q "$TMP/wt" -b wtbranch >/dev/null 2>&1
# The expected git-common-dir is whatever git resolves for the LINKED worktree (an
# absolute, symlink-canonicalized path pointing at the MAIN repo's shared .git) -
# exactly what emit-settings resolves. Deriving it from git keeps the assertion
# honest across hosts that canonicalize /var -> /private/var etc.
MAIN_GIT=$(git -C "$TMP/wt" rev-parse --path-format=absolute --git-common-dir)
MAIN_GIT=${MAIN_GIT%/}

TASK_TMP="/tmp/fm-sbxtest"
TURNEND="$TMP/home/state/sbxtest.turn-ended"
settings=$("$POLICY" emit-settings "$TMP/wt" "$TASK_TMP" "$TURNEND") || fail "emit-settings failed for a linked worktree"

sneed() { case "$settings" in *"$1"*) pass "settings: $2" ;; *) fail "settings: $2 (missing: $1)" ;; esac; }

# Network: authoritative egress allowlist + empty deniedDomains.
sneed '"api.anthropic.com"'                         "Anthropic API is allowlisted"
sneed '"mavtek-840225427682.d.codeartifact.us-east-1.amazonaws.com"' "CodeArtifact host is allowlisted"
sneed '"*.github.com"'                              "GitHub is allowlisted"
sneed '"deniedDomains": []'                         "deniedDomains is empty"
case "$settings" in *npmjs*) fail "settings: npmjs must NOT be allowlisted (packages route through CodeArtifact)" ;; *) pass "settings: npmjs is not allowlisted" ;; esac

# Filesystem reads: the credential dirs are denied.
sneed '"denyRead": ["~/.ssh", "~/.aws", "~/.config/gh"]' "denyRead covers ~/.ssh, ~/.aws, ~/.config/gh"

# Filesystem writes: worktree, task-tmp, the resolved ABSOLUTE git-common-dir + /**,
# the SINGLE turn-end file, and claude's home config.
sneed "\"$TASK_TMP\""                               "allowWrite includes the resolved \$TASK_TMP"
sneed "\"$MAIN_GIT\""                               "allowWrite includes the resolved absolute git-common-dir (main repo, not the worktree)"
sneed "\"$MAIN_GIT/**\""                            "allowWrite includes everything under the git-common-dir"
sneed "\"$TURNEND\""                                "allowWrite includes the single turn-ended file"
sneed '"~/.claude"'                                 "allowWrite includes ~/.claude"
sneed '"~/.claude.json"'                            "allowWrite includes ~/.claude.json"

# The turn-end allow is a SINGLE file, never the whole state dir.
case "$settings" in
  *"\"$TMP/home/state\""|*"\"$TMP/home/state\","*|*"\"$TMP/home/state/**\""*)
    fail "settings: turn-end allow must be the single .turn-ended file, not the whole state dir" ;;
  *) pass "settings: turn-end allow is a single file (not the whole state dir)" ;;
esac

# denyWrite re-blocks the parent .git/config and hooks (deny wins over the whole-dir allow).
sneed "\"$MAIN_GIT/config\""                        "denyWrite re-blocks the parent .git/config"
sneed "\"$MAIN_GIT/config.**\""                     "denyWrite re-blocks .git/config.* variants"
sneed "\"$MAIN_GIT/hooks\""                         "denyWrite re-blocks .git/hooks"
sneed "\"$MAIN_GIT/hooks/**\""                      "denyWrite re-blocks everything under .git/hooks"

# The git-common-dir must be resolved per worktree: a plain repo resolves to its own
# .git, which is a DIFFERENT path than the linked worktree's shared common dir above.
git -C "$TMP" init -q solo
SOLO_GIT=$(git -C "$TMP/solo" rev-parse --path-format=absolute --git-common-dir)
SOLO_GIT=${SOLO_GIT%/}
[ "$SOLO_GIT" != "$MAIN_GIT" ] || fail "test setup: solo and main git-common-dir unexpectedly identical"
solo=$("$POLICY" emit-settings "$TMP/solo" "$TASK_TMP" "$TURNEND") || fail "emit-settings failed for a plain repo"
case "$solo" in
  *"\"$SOLO_GIT\""*) pass "settings: git-common-dir is resolved per worktree (differs from the linked worktree's shared .git)" ;;
  *) fail "settings: a plain repo's git-common-dir must resolve to its own .git" ;;
esac

# Valid JSON (when a parser is available).
if command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "$settings" | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "srt-settings.json is not valid JSON"
  pass "srt-settings.json parses as valid JSON"
else
  echo "warn: python3 unavailable; skipped JSON parse validation" >&2
fi

# ---------------------------------------------------------------------------
# 4. POLICY OWNER resolution + preflight refusal semantics.
# ---------------------------------------------------------------------------
# resolve prints a usable srt invocation (srt on PATH, else the npx fallback) when
# either is available; this host has one, so it must be non-empty.
if command -v srt >/dev/null 2>&1 || command -v npx >/dev/null 2>&1; then
  rcmd=$("$POLICY" resolve) || fail "resolve failed though srt/npx is available"
  [ -n "$rcmd" ] || fail "resolve returned empty though srt/npx is available"
  pass "resolve returns a usable srt invocation: $rcmd"
else
  echo "warn: neither srt nor npx present; skipped resolve check" >&2
fi

# version never fails the caller (informational; "unknown" is acceptable).
"$POLICY" version >/dev/null || fail "version must never fail the caller"
pass "version is best-effort and never fails the caller"

# emit-settings refuses (nonzero) for a non-git directory rather than emitting junk.
mkdir -p "$TMP/notgit"
if "$POLICY" emit-settings "$TMP/notgit" "$TASK_TMP" "$TURNEND" >/dev/null 2>&1; then
  fail "emit-settings should refuse a non-git worktree"
fi
pass "emit-settings refuses a non-git worktree instead of emitting an unsafe settings file"

echo "PASS: fm-spawn-sandbox"
