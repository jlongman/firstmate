# Crewmate OS confinement (optional, srt)

Firstmate can wrap a claude crewmate in an OS sandbox using Anthropic's sandbox-runtime (`srt`).
It is optional and off by default, so nothing changes for a home that does not opt in.
This document is the operator reference for the feature; `bin/fm-spawn.sh` and `bin/fm-check-sandbox-policy.sh` own the exact launch mechanics, and the private scout report `data/srt-sandbox-spike/report.md` holds the empirical evidence behind every choice here.

## The gap it closes

Firstmate already isolates crewmates three ways: the first mate is read-only over projects, crewmates work in disposable worktrees, and no-mistakes gates every PR.
None of those is process confinement.
An autonomous crewmate still runs with the launching user's full reach: it can read any file the user can, write anywhere, and reach any host.
`srt` adds that missing layer for the claude harness by wrapping the whole claude process (its built-in Read, Edit, and WebFetch tools and any MCP server, not just Bash) in a filesystem and network boundary enforced by the OS.

Under `srt`, `claude --dangerously-skip-permissions` stays on the launch line.
Inside the wall that flag is the sanctioned autonomy mechanism, not a boundary bypass: the OS boundary still enforces, verified in the scout report, so the crewmate runs unattended while confined.

## Turning it on: config/crew-sandbox

The mode is a local, gitignored `config/crew-sandbox` file under the effective home, following the same convention as the other `config/*` knobs (see [`docs/configuration.md`](configuration.md#crew-sandbox-configcrew-sandbox), the owner of the schema and mode semantics).
There are three values:

- `off` (the default; an absent file is off) launches exactly as before, byte-identical, with no sandbox.
- `srt` (alias `on`) wraps the launch in `srt`, or refuses the spawn if the preflight fails, so a home that asks for confinement never silently launches without it.
- `auto` wraps the launch when the preflight passes and otherwise falls back to a plain launch with a loud warning.

Confinement covers claude ship and scout crewmates only.
Another harness, or a secondmate, launches unchanged even when the knob is set, with a warning so the unconfined launch is never silent.
The posture is recorded in each task's durable record as `sandbox=on|off`.

## What the boundary allows

For an `srt` launch, `bin/fm-check-sandbox-policy.sh` writes a per-task `srt-settings.json` into the worktree (git-excluded, like the other generated worktree files).
That script is the single owner of the settings shape; the shape is summarized here, not restated as a second copy.

- Network egress is an allowlist: the Anthropic API and its telemetry, Sentry, GitHub, and the org's CodeArtifact registry host, with everything else blocked.
- Credential reads are denied: `~/.ssh`, `~/.aws`, and `~/.config/gh`.
- Writes are limited to the worktree, the task's temp root, the shared git-common-dir (so branch, ref, and index writes work in a linked worktree), claude's own home config, and the single turn-end signal file.
- Writes to the parent `.git/config` and `.git/hooks` are re-blocked even though the whole git-common-dir is writable, because allowing them would let a crewmate set a hook or filter and gain code execution on the next git operation in the parent checkout.

Two caveats are engineered into the launch rather than left to `srt`:

- `srt` does not touch environment variables, so `bin/fm-spawn.sh` scrubs the secret vars (`ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `GH_TOKEN`, and the three `AWS_*` session vars) with `env -u` outside the wall before wrapping.
- The turn-end Stop hook is unchanged; it fires under the wall because the one file it touches is a single-file write allow, never the whole state directory.

## CodeArtifact packages

When a repo uses the org's CodeArtifact registry, the sandboxed crewmate cannot authenticate to it (the boundary denies `~/.aws` and the AWS env vars are scrubbed).
So `bin/fm-spawn.sh` vends the short-lived npm token outside the sandbox, as the launching user with a live AWS session, into a worktree-local `.npmrc` that the crewmate only reads.
The token is only ever written to an untracked worktree `.npmrc`, never a git-tracked one: if the repo commits its own `.npmrc`, the vend refuses with a warning and leaves the tracked file alone, so a live token can never land in a tracked modification an autonomous crewmate might commit and push.
The vend is best-effort: on failure it warns and launches anyway, and the token is short-lived, so it is vended fresh on every spawn.

## Preflight

`bin/fm-check-sandbox-policy.sh preflight` is the doctor an `srt` or `auto` spawn runs before launch.
It confirms `srt` is resolvable (on `PATH`, or via `npx -y @anthropic-ai/sandbox-runtime`), that ripgrep is present on macOS, and that a smoke sandbox initializes cleanly on this host.
That smoke run is the only check that proves enforcement can actually start here; the config-correctness tests cannot.
`srt`/`on` treats a preflight failure as a refusal, `auto` treats it as a fall-back-to-plain with a warning, and `off` skips the preflight entirely.

## Verifying enforcement

The colocated test (`tests/fm-spawn-sandbox.test.sh`) proves the launch and the settings are generated correctly; it cannot prove the OS enforces them.
A host where the sandbox fails to initialize passes that test and is still unconfined unless the preflight refuses first.
To confirm real enforcement on a host, follow the probe recipe in the scout report `data/srt-sandbox-spike/report.md` (section 2): from inside a wrapped crewmate, a denied home-path read returns an OS permission error, a worktree write succeeds, an unlisted host is blocked, and an allowlisted host connects.

## Maturity note

`srt` is a beta research preview whose config format may still shift, and it is an npm dependency that now wraps every confined crewmate, so pin and audit it like any other confinement-critical dependency.
The Linux path uses bubblewrap rather than Seatbelt and is literal-path-only for globs; re-verify the settings generator there before relying on it, per the scout report.
