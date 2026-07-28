#!/usr/bin/env bash
# fm-check-sandbox-policy.sh - srt (Anthropic sandbox-runtime) policy owner for
# claude crewmate OS confinement. Single owner of three things: how srt is
# invoked on this host, the srt preflight doctor, and the per-task
# srt-settings.json shape (the egress allowlist, credential-read denials, and the
# worktree/git write scope). bin/fm-spawn.sh consults this script; it never
# restates the allowlist or the settings shape.
#
# See docs/crewmate-sandbox.md for the design and the caveat each check guards,
# and the private scout report data/srt-sandbox-spike/report.md for the empirical
# evidence behind them.
#
# Usage:
#   fm-check-sandbox-policy.sh preflight
#       Doctor for a spawn that requires srt. Verifies srt is resolvable (on PATH
#       or via `npx -y @anthropic-ai/sandbox-runtime`), that ripgrep is present on
#       macOS (srt's Seatbelt dependency), and that a smoke `srt ... -c 'true'`
#       initializes cleanly - the only check that proves enforcement can actually
#       start on THIS host, which the unit tests cannot do. Prints diagnostics to
#       stderr and exits nonzero with a clear reason on any failure.
#   fm-check-sandbox-policy.sh resolve
#       Print the srt invocation prefix ("srt" when on PATH, otherwise
#       "npx -y @anthropic-ai/sandbox-runtime"). Exits nonzero with no output when
#       neither srt nor npx is available.
#   fm-check-sandbox-policy.sh version
#       Best-effort srt PACKAGE version, read from its package.json (never
#       `srt --version`, which mis-reports 1.0.0). Prints "unknown" when it cannot
#       be resolved; never fails the caller.
#   fm-check-sandbox-policy.sh emit-settings <worktree> <task-tmp> <turn-ended>
#       Print the per-task srt-settings.json to stdout. Resolves the worktree's
#       ABSOLUTE git-common-dir (it differs per worktree) so writes to the shared
#       git dir succeed for refs and the index, while denyWrite re-blocks the
#       parent .git/config and .git/hooks that the whole-common-dir allow would
#       otherwise re-expose (a real escalation vector; report section 3b).
set -eu

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
}

# The authoritative crewmate egress allowlist (network.allowedDomains). This is
# the list empirically verified to run claude autonomously while confined
# (data/srt-sandbox-spike/report.md section 1): the Anthropic API and its
# telemetry, Sentry, GitHub, and the org's CodeArtifact registry host. Kept as the
# single copy so it never drifts; docs/crewmate-sandbox.md points here.
SRT_ALLOWED_DOMAINS='
api.anthropic.com
statsig.anthropic.com
*.sentry.io
mavtek-840225427682.d.codeartifact.us-east-1.amazonaws.com
github.com
*.github.com
codeload.github.com
*.githubusercontent.com
'

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Print the srt invocation prefix, or return 1 with no output when unavailable.
# srt on PATH wins; otherwise fall back to the pinned npx package invocation.
resolve_srt_cmd() {
  if command -v srt >/dev/null 2>&1; then
    printf 'srt\n'
    return 0
  fi
  if command -v npx >/dev/null 2>&1; then
    printf 'npx -y @anthropic-ai/sandbox-runtime\n'
    return 0
  fi
  return 1
}

# Best-effort installed package version. The srt CLI's --version is decoupled from
# the package and reports 1.0.0, so resolve the package.json instead. Informational
# only: prints "unknown" rather than failing when it cannot be determined.
srt_version() {
  local v=
  v=$(node -e 'try{process.stdout.write(require("@anthropic-ai/sandbox-runtime/package.json").version)}catch(e){process.exit(3)}' 2>/dev/null) || v=
  [ -n "$v" ] || v=unknown
  printf '%s\n' "$v"
}

# Print the per-task srt-settings.json for one worktree spawn.
emit_settings() {
  local wt=$1 task_tmp=$2 turnend=$3 gcd domains_json d first ej_tmp ej_gcd ej_turn
  [ -n "$wt" ] && [ -n "$task_tmp" ] && [ -n "$turnend" ] || {
    echo "error: emit-settings needs <worktree> <task-tmp> <turn-ended>" >&2
    return 2
  }
  gcd=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "error: cannot resolve git-common-dir for worktree: $wt" >&2
    return 1
  }
  gcd=${gcd%/}

  domains_json=
  first=1
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$first" = 1 ]; then first=0; else domains_json="$domains_json, "; fi
    domains_json="$domains_json\"$(json_escape "$d")\""
  done <<EOF
$SRT_ALLOWED_DOMAINS
EOF

  ej_tmp=$(json_escape "$task_tmp")
  ej_gcd=$(json_escape "$gcd")
  ej_turn=$(json_escape "$turnend")

  # allowWrite scope, in order: the worktree (.), the task temp root (Go build temp
  # and other per-task scratch; srt does not auto-add it), the shared git-common-dir
  # and everything under it (branch/ref/index writes in a linked worktree), the
  # SINGLE turn-end file outside the worktree (the Stop hook's only external write -
  # never the whole state/ dir), and claude's own home config it writes at runtime.
  # denyWrite wins over allowWrite and re-blocks the parent .git/config and hooks.
  cat <<EOF
{
  "network": {
    "allowedDomains": [$domains_json],
    "deniedDomains": []
  },
  "filesystem": {
    "denyRead": ["~/.ssh", "~/.aws", "~/.config/gh"],
    "allowWrite": [
      ".",
      "$ej_tmp",
      "$ej_gcd",
      "$ej_gcd/**",
      "$ej_turn",
      "~/.claude",
      "~/.claude.json"
    ],
    "denyWrite": [
      "$ej_gcd/config",
      "$ej_gcd/config.**",
      "$ej_gcd/hooks",
      "$ej_gcd/hooks/**"
    ]
  }
}
EOF
}

# Full doctor for a spawn that requires srt. Any failure returns nonzero with a
# SANDBOX_PREFLIGHT: reason on stderr; callers decide refuse vs plain-launch.
preflight() {
  local srt_cmd rc tmp settings ver
  if ! srt_cmd=$(resolve_srt_cmd); then
    echo "SANDBOX_PREFLIGHT: srt is unavailable - neither 'srt' on PATH nor 'npx' to run @anthropic-ai/sandbox-runtime" >&2
    return 1
  fi
  if [ "$(uname -s)" = Darwin ] && ! command -v rg >/dev/null 2>&1; then
    echo "SANDBOX_PREFLIGHT: ripgrep (rg) is required by srt on macOS but was not found on PATH" >&2
    return 1
  fi
  ver=$(srt_version)
  echo "SANDBOX_PREFLIGHT: srt invocation '$srt_cmd' (package version: $ver)" >&2
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-srt-preflight.XXXXXX") || {
    echo "SANDBOX_PREFLIGHT: could not create a temp dir for the smoke check" >&2
    return 1
  }
  settings="$tmp/srt-settings.json"
  printf '%s\n' '{"network":{"allowedDomains":[],"deniedDomains":[]},"filesystem":{"denyRead":[],"allowWrite":["."],"denyWrite":[]}}' > "$settings"
  # shellcheck disable=SC2086  # srt_cmd is a command prefix; intentional word-split.
  if $srt_cmd --settings "$settings" -c 'true' >/dev/null 2>"$tmp/err"; then
    echo "SANDBOX_PREFLIGHT: smoke sandbox initialized cleanly" >&2
    rm -rf "$tmp"
    return 0
  fi
  rc=$?
  echo "SANDBOX_PREFLIGHT: srt failed to initialize a smoke sandbox (exit $rc):" >&2
  sed 's/^/    /' "$tmp/err" >&2 2>/dev/null || true
  rm -rf "$tmp"
  return 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  preflight) preflight ;;
  resolve) resolve_srt_cmd ;;
  version) srt_version ;;
  emit-settings) shift; emit_settings "${1:-}" "${2:-}" "${3:-}" ;;
  '') echo "error: missing subcommand (preflight|resolve|version|emit-settings)" >&2; exit 2 ;;
  *) echo "error: unknown subcommand '$1' (preflight|resolve|version|emit-settings)" >&2; exit 2 ;;
esac
