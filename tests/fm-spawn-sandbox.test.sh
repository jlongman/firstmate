#!/usr/bin/env bash
# Test: user-configurable crewmate OS confinement via srt (docs/crewmate-sandbox.md).
#
# Behavioral coverage (per the repo's behavioral-over-source-content test convention):
# every check EXERCISES the shipped code - the launch-template builder, the
# config/crew-sandbox mode resolution, the CodeArtifact vend guard, and the
# srt-settings.json generator - rather than grepping fm-spawn.sh source text. The
# blocks that live in fm-spawn.sh's main body (which needs a live backend to run
# end-to-end) are extracted and driven in isolation with stubs and fixtures.
#
#   - srt OFF (default; config/crew-sandbox absent or "off"): the plain launch,
#     byte-identical to before this change - claude --dangerously-skip-permissions
#     with the unchanged __OPINPUT__ brief-passing, no srt, no env scrub.
#   - srt ON (config/crew-sandbox = srt|on|auto): the launch wrapped in
#     `env -u <secrets> srt --settings <file> ... claude --dangerously-skip-permissions`,
#     plus a correct srt-settings.json (network allowlist, denyRead, allowWrite with
#     the resolved absolute git-common-dir and a SINGLE-file turn-end allow, and a
#     denyWrite that re-blocks the parent .git/config, hooks, and claude's own hooks).
#
# This proves the config is GENERATED correctly. It CANNOT assert the OS sandbox
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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-sandbox.XXXXXX"); trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# 1. LAUNCH TEMPLATES: extract launch_template() and exercise both paths.
# ---------------------------------------------------------------------------
# The function is self-contained (printf + case, no globals), so eval it in
# isolation and assert on the command string it PRODUCES (its behavior), not on the
# source file. This directly proves off vs on without a live session.
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

# The scrub must run OUTSIDE the wall: env -u ... must precede __SRTCMD__. The
# CLAUDE_CONFIG_DIR forwarding prefix (fm-spawn.sh, upstream #1195) does NOT strip
# CLAUDE_CONFIG_DIR here - the scrub list is exactly the six secret vars.
case "$srt" in
  *"env -u ANTHROPIC_API_KEY"*"__SRTCMD__ --settings"*) pass "env scrub runs outside srt (srt does not scrub env itself)" ;;
  *) fail "srt-on launch must scrub env BEFORE the srt invocation" ;;
esac
case "$srt" in
  *CLAUDE_CONFIG_DIR*) fail "the srt scrub list must not mention CLAUDE_CONFIG_DIR (it must reach the sandboxed claude)" ;;
  *) pass "the env scrub does not strip CLAUDE_CONFIG_DIR (auth store forwarding survives into the sandbox)" ;;
esac

# ---------------------------------------------------------------------------
# 2. CONFIG-MODE RESOLUTION (behavioral: extract the block and run it).
# ---------------------------------------------------------------------------
# fm-spawn.sh resolves config/crew-sandbox into CREW_SANDBOX_MODE + SANDBOX_ACTIVE
# (and refuses/warns) before any worktree exists. Extract that block and drive it
# with a stub policy script + real config fixtures, asserting the resolved outcome
# and the fail-closed exit - real behavior, not a source grep.
MODE_BLOCK=$(awk '/^CREW_SANDBOX_MODE=off$/{f=1} f{print} /^fi$/&&f{n++} f&&n==2{exit}' "$SPAWN")
[ -n "$MODE_BLOCK" ] || fail "could not extract the crew-sandbox mode-resolution block from fm-spawn.sh"

STUB_DIR="$TMP/stub"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/fm-check-sandbox-policy.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  preflight) exit "${STUB_PREFLIGHT_RC:-0}" ;;
  resolve)   if [ "${STUB_RESOLVE_OK:-1}" = 1 ]; then echo srt; exit 0; fi; exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_DIR/fm-check-sandbox-policy.sh"

# run_mode <config-value|__ABSENT__> <kind> <harness> <preflight_rc> <resolve_ok>
# Prints "MODE=<mode> ACTIVE=<0|1>" on a completed (non-refusing) resolution; a
# refusal exits non-zero and prints nothing. Stderr is captured to $TMP/mode.err.
run_mode() {
  local cfgval=$1 kind=$2 harness=$3 pf=$4 rok=$5 cfgdir
  cfgdir=$(mktemp -d "$TMP/cfg.XXXXXX")
  [ "$cfgval" = "__ABSENT__" ] || printf '%s' "$cfgval" > "$cfgdir/crew-sandbox"
  (
    set +e
    export STUB_PREFLIGHT_RC="$pf" STUB_RESOLVE_OK="$rok"
    # shellcheck disable=SC2034  # consumed inside the evaluated MODE_BLOCK
    CONFIG=$cfgdir KIND=$kind HARNESS=$harness SCRIPT_DIR=$STUB_DIR
    eval "$MODE_BLOCK"
    echo "MODE=$CREW_SANDBOX_MODE ACTIVE=$SANDBOX_ACTIVE"
  ) 2>"$TMP/mode.err"
}

expect_mode() { # <label> <expected "MODE=.. ACTIVE=..">  reads $out/$rc from caller
  if [ "$rc" -ne 0 ]; then fail "$1: resolution refused (exit $rc) but expected to complete"; fi
  [ "$out" = "$2" ] || fail "$1: expected '$2', got '$out'"
  pass "$1"
}
expect_refuse() { # <label> <stderr-substring>
  [ "$rc" -ne 0 ] || fail "$1: expected a fail-closed refusal (non-zero exit) but it completed: '$out'"
  case "$(cat "$TMP/mode.err")" in
    *"$2"*) pass "$1" ;;
    *) fail "$1: refused but the reason did not match '$2'" ;;
  esac
}

# absent / off / off-with-trailing-comment -> off, inactive (the #first-token parse:
# trailing content after the first token must not break the default).
if out=$(run_mode __ABSENT__ ship claude 0 1); then rc=0; else rc=$?; fi
expect_mode "absent config -> off, inactive" "MODE=off ACTIVE=0"
if out=$(run_mode "off" ship claude 0 1); then rc=0; else rc=$?; fi
expect_mode "off -> off, inactive" "MODE=off ACTIVE=0"
if out=$(run_mode "$(printf 'off\n# a trailing comment line\n')" ship claude 0 1); then rc=0; else rc=$?; fi
expect_mode "first-token parse: 'off' + trailing content -> off (no hard-fail)" "MODE=off ACTIVE=0"

# srt / on / SRT (case-insensitive) -> srt, active for a claude crewmate when preflight passes.
if out=$(run_mode "srt" ship claude 0 1); then rc=0; else rc=$?; fi
expect_mode "srt (claude, preflight ok) -> srt, active" "MODE=srt ACTIVE=1"
if out=$(run_mode "on" scout claude 0 1); then rc=0; else rc=$?; fi
expect_mode "on is an alias for srt -> srt, active" "MODE=srt ACTIVE=1"
if out=$(run_mode "SRT" ship claude 0 1); then rc=0; else rc=$?; fi
expect_mode "value is case-insensitive (SRT) -> srt, active" "MODE=srt ACTIVE=1"
if out=$(run_mode "auto" ship claude 0 1); then rc=0; else rc=$?; fi
expect_mode "auto (claude, preflight ok) -> auto, active" "MODE=auto ACTIVE=1"

# Preflight failure: strict srt REFUSES; auto falls back to a plain (inactive) launch.
if out=$(run_mode "srt" ship claude 1 1); then rc=0; else rc=$?; fi
expect_refuse "srt + failing preflight refuses the spawn (fail closed)" "refusing to launch unconfined"
if out=$(run_mode "auto" ship claude 1 1); then rc=0; else rc=$?; fi
expect_mode "auto + failing preflight -> auto, inactive (warn + plain launch)" "MODE=auto ACTIVE=0"

# An unrecognized value is a hard error, never a silent default.
if out=$(run_mode "bogus" ship claude 0 1); then rc=0; else rc=$?; fi
expect_refuse "unrecognized config value refuses" "unrecognized value"

# Fail closed for a worker srt cannot wrap: strict srt REFUSES a non-claude crewmate
# or any secondmate; auto only warns and launches unconfined.
if out=$(run_mode "srt" ship codex 0 1); then rc=0; else rc=$?; fi
expect_refuse "strict srt refuses a non-claude crewmate (fail closed)" "refusing to launch codex ship unconfined"
if out=$(run_mode "srt" secondmate claude 0 1); then rc=0; else rc=$?; fi
expect_refuse "strict srt refuses a secondmate (fail closed)" "refusing to launch claude secondmate unconfined"
if out=$(run_mode "auto" ship codex 0 1); then rc=0; else rc=$?; fi
expect_mode "auto + non-claude -> auto, inactive (warn + unconfined launch)" "MODE=auto ACTIVE=0"
if out=$(run_mode "auto" secondmate claude 0 1); then rc=0; else rc=$?; fi
expect_mode "auto + secondmate -> auto, inactive (warn + unconfined launch)" "MODE=auto ACTIVE=0"

# ---------------------------------------------------------------------------
# 3. CodeArtifact vend guard (behavioral: extract the vend block and run it).
# ---------------------------------------------------------------------------
# The vend must NEVER write a live token into a git-tracked .npmrc (a dirty tracked
# file an autonomous crewmate could commit). Extract the _ca_* host derivation plus
# the vend guard and drive it against tracked / untracked fixtures with a stub aws.
CA_VARS=$(awk '/_ca_domain=/{f=1} f{print} /_ca_host=/{exit}' "$SPAWN")
VEND_GUARD=$(awk '/grep -qs .codeartifact./{f=1} f{print} f&&/^        fi$/{exit}' "$SPAWN")
[ -n "$CA_VARS" ] || fail "could not extract the _ca_* host derivation from fm-spawn.sh"
[ -n "$VEND_GUARD" ] || fail "could not extract the CodeArtifact vend guard from fm-spawn.sh"
VEND_BLOCK="$CA_VARS
$VEND_GUARD"

# run_vend <absent|tracked|untracked> <aws-ok|aws-fail>  -> sets $VWT (worktree),
# writes stderr to $TMP/vend.err. .npmrc content is inspected by the caller.
run_vend() {
  local state=$1 aws=$2
  VWT=$(mktemp -d "$TMP/vend.XXXXXX")
  git -C "$VWT" init -q
  case "$state" in
    tracked)
      printf 'registry=https://host/codeartifact/npm/\n' > "$VWT/.npmrc"
      git -C "$VWT" add .npmrc
      git -C "$VWT" -c user.email=t@t -c user.name=t commit -q -m npmrc ;;
    untracked)
      printf 'registry=https://host/codeartifact/npm/\n' > "$VWT/.npmrc" ;;
    absent) : ;;
  esac
  (
    set +e
    # shellcheck disable=SC2034  # consumed inside the evaluated VEND_BLOCK
    WT=$VWT ID=vend-test FM_CODEARTIFACT_DOMAIN=mavtek
    # shellcheck disable=SC2329  # invoked inside the evaluated VEND_BLOCK
    exclude_path() { :; }
    # shellcheck disable=SC2329  # invoked inside the evaluated VEND_BLOCK
    if [ "$aws" = aws-ok ]; then aws() { echo "tok-STUB-123"; }; else aws() { return 1; }; fi
    eval "$VEND_BLOCK"
  ) 2>"$TMP/vend.err"
}

run_vend tracked aws-ok
case "$(cat "$TMP/vend.err")" in
  *"refusing to vend a CodeArtifact token into a tracked file"*) : ;;
  *) fail "vend: a tracked .npmrc must be refused with a warning" ;;
esac
case "$(cat "$VWT/.npmrc")" in
  *_authToken*) fail "vend: a tracked .npmrc must NOT be overwritten with a live token" ;;
  *) pass "vend: tracked .npmrc is refused - no token written into git's view" ;;
esac

run_vend untracked aws-ok
case "$(cat "$VWT/.npmrc")" in
  *"_authToken=tok-STUB-123"*) pass "vend: untracked .npmrc receives the vended token" ;;
  *) fail "vend: an untracked .npmrc must receive the vended token" ;;
esac

run_vend untracked aws-fail
case "$(cat "$TMP/vend.err")" in
  *"CodeArtifact token vend failed"*) : ;;
  *) fail "vend: a failed token fetch must warn" ;;
esac
case "$(cat "$VWT/.npmrc")" in
  *_authToken*) fail "vend: a failed token fetch must not write a token" ;;
  *) pass "vend: a failed token fetch warns and writes no token" ;;
esac

# ---------------------------------------------------------------------------
# 4. srt-settings.json SHAPE (behavioral, via the policy owner). No srt needed.
# ---------------------------------------------------------------------------
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
# The 3-arg call (no CodeArtifact host) yields the default org host, byte-identical
# to before the host became a parameter.
sneed '"mavtek-840225427682.d.codeartifact.us-east-1.amazonaws.com"' "3-arg emit-settings allowlists the default CodeArtifact host"
sneed '"*.github.com"'                              "GitHub is allowlisted"
sneed '"deniedDomains": []'                         "deniedDomains is empty"
case "$settings" in *npmjs*) fail "settings: npmjs must NOT be allowlisted (packages route through CodeArtifact)" ;; *) pass "settings: npmjs is not allowlisted" ;; esac

# A non-default CodeArtifact host (4th arg) must flow into network.allowedDomains, so
# the allowlist host and the vended-token host in fm-spawn.sh cannot drift when
# FM_CODEARTIFACT_DOMAIN/OWNER/REGION are overridden.
CA_ALT='acme-111122223333.d.codeartifact.eu-west-1.amazonaws.com'
settings_alt=$("$POLICY" emit-settings "$TMP/wt" "$TASK_TMP" "$TURNEND" "$CA_ALT") || fail "emit-settings failed with a CodeArtifact host argument"
case "$settings_alt" in
  *"\"$CA_ALT\""*) pass "settings: a non-default CodeArtifact host argument flows into network.allowedDomains" ;;
  *) fail "settings: the CodeArtifact host argument must appear in network.allowedDomains" ;;
esac
case "$settings_alt" in
  *'mavtek-840225427682.d.codeartifact.us-east-1.amazonaws.com'*) fail "settings: the default host must be REPLACED by the host argument, not both present" ;;
  *) pass "settings: the host argument replaces the default (no drift between allowlist and vend)" ;;
esac

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

# allowWrite includes claude's per-user Bash-tool shell-scratch root (both the
# /private/tmp real path and the /tmp alias) so a confined crewmate's Bash tool can
# create its shell working dir under /private/tmp/claude-<uid>/ instead of dying on
# mkdir EPERM. This is the write that unblocks git/gh/npm inside the wall.
CLAUDE_UID=$(id -u)
sneed "\"/private/tmp/claude-$CLAUDE_UID\""          "allowWrite includes claude's shell-scratch root (/private/tmp real path)"
sneed "\"/private/tmp/claude-$CLAUDE_UID/**\""       "allowWrite includes everything under claude's shell-scratch root"
sneed "\"/tmp/claude-$CLAUDE_UID\""                  "allowWrite includes the /tmp alias of claude's shell-scratch root"

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

# denyWrite ALSO re-blocks claude's own hook-execution config, exactly like the parent
# .git/config and hooks: a confined crewmate must not be able to plant a global hook
# that runs in the captain's future unconfined claude sessions. ~/.claude stays
# writable (session/telemetry state); only the settings/hook paths are re-blocked.
sneed '"~/.claude/settings.json"'                   "denyWrite re-blocks ~/.claude/settings.json"
sneed '"~/.claude/settings.local.json"'             "denyWrite re-blocks ~/.claude/settings.local.json"
sneed '"~/.claude/hooks"'                           "denyWrite re-blocks ~/.claude/hooks"
sneed '"~/.claude/hooks/**"'                         "denyWrite re-blocks everything under ~/.claude/hooks"

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
# 5. POLICY OWNER resolution + refusal semantics.
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
