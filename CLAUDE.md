# Agent / developer reference

This file is for anyone (human or agent) making code changes. End-user install
and usage live in `README.md`; the architecture overview lives here, with the
detailed rationale for each state-machine decision in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — read it before touching
state-transition logic in `tab-title.sh` or `sweep-bell-state.sh`.

## Contents

- [Session start](#session-start)
- [Post-change checklist](#post-change-checklist)
- [Architecture](#architecture)
  - [Why state files instead of AppleScript tab enumeration](#why-state-files-instead-of-applescript-tab-enumeration)
  - [Why `refreshallplugins` vs `refreshplugin?name=…`](#why-refreshallplugins-vs-refreshpluginname)
- [Scripts](#scripts)
- [Environment variables](#environment-variables)
- [Validator](#validator)
- [Picking SF Symbols](#picking-sf-symbols)
- [Gotchas](#gotchas)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — watching state,
  agents-running state, pending-input set, deferred completion
  notification, refresh gating, event log dedup, stale-state cleanup, and
  the dashboard north-star metric

## Session start

**Read `~/.claude/.ccg/changelog.md` before doing any work in this repo.**
The `SessionStart` hook (`.claude/hooks/fetch-changelog.sh`) fetches the Claude Code
changelog and caches it there (12 h TTL). Use the `Read` tool to load it into
context. Missing a changelog entry has caused real debugging time (e.g.
`terminalSequence` was in the 2.1.141 notes but unknown until we hit the
problem). This hook lives in `.claude/settings.json` (project-scoped,
untracked) — absent from both the root `settings.json` and
`~/.claude/settings.json` so it fires only for sessions in this repo.

## Post-change checklist

After every change, verify the following in order:

1. **Validator** — run `./tests/validate.sh`. It must pass. If the change
   introduces new behavior, extend the validator to cover it before considering
   the change complete.
2. **Tab title verification** — to confirm a title change took effect in a
   live session, use one of: `tail ~/.claude/.ccg/termseq.log` (every
   `tab-title.sh` run appends a timestamped line with the exact title and
   session id), or osascript to read Ghostty's current tab titles. Do not
   rely on the user manually confirming.
3. **Tab targeting** — will notifications still focus the correct tab?
   `focus-ghostty-tab.sh` uses contains-match against AX tab titles; confirm
   the title stored in state files and passed via `terminal-notifier` still
   uniquely identifies the session.
4. **Notification text** — does any user-visible string need updating?
5. **README.md** — does the human-facing documentation still reflect the
   current install flow? (Architecture details don't belong there.)
6. **Dashboard** — open `.ccg/dashboard.html` and inspect every place that
   enumerates session states (the `STATES` constant, per-state arrays in
   `compute()`, the "Right now" cards, the "Last 24 hours · totals"
   cards, the chart datasets, the `render()` block). If the change adds
   or renames a state, every one of those must be updated; if it adds a
   new metric, decide whether the dashboard should surface it. **For
   any dashboard change, always (a) deploy the updated file to
   `~/.claude/.ccg/dashboard.html` — don't ask, this overrides item 7 —
   then (b) view it through the running server via the
   `chrome-devtools` MCP, list console messages, and take a snapshot or
   screenshot. Treat any console error, network failure, or visibly
   broken section as a blocking issue and fix it before moving on.**
   The point is to surface render bugs (missing canvases, undefined
   refs, mis-sized charts) before the user sees them, not just to
   confirm the file parses.
7. **Hook parity** — `settings.json` (project) and `~/.claude/settings.json`
   (global) must define the same core hook events (`SessionStart`,
   `Notification`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure`,
   `SessionEnd`) with identical matchers and commands. The global file may have
   additional hooks (`PreToolUse`/unfence, `SubagentStop`/agent-arena,
   `Stop`/sync-permissions) that are intentionally absent from the project
   file. **Project-specific hooks go in `.claude/settings.json`** (not in the
   root `settings.json`, which is the source for the deployed global config;
   not in `~/.claude/settings.json`). Their scripts live in `.claude/hooks/`,
   not in `hooks/`. Any change to a shared hook must be applied to **both** the
   root `settings.json` and `~/.claude/settings.json`.
8. **Local deploy** — ask the user whether the change should be copied to
   `~/.claude/hooks/` / `~/swiftbar/` / `~/.claude/.ccg/`.
9. **Commit and push** — every change ends with a commit and a push to
   *all* configured remotes (this overrides the default "only commit
   when explicitly asked" rule for this repo). Remotes to push to are
   whatever `git remote` lists; today that's `origin` and `trilogy`.
   Push to each one in sequence.
   **Always hold the commit and push until the new feature or fix is
   proven working** — not just for bug fixes but for any new behavior.
   "Proven" means the user has confirmed it behaves correctly in
   practice (or there is concrete in-situ evidence it does), NOT merely
   that the validator passes or the code looks right. The validator and
   local diagnostics are necessary but not sufficient. Deploy to
   `~/.claude/...` so the change can be exercised live, then wait. Once
   the user confirms it's working, commit and push immediately without
   asking.

## Architecture

Four layers cooperate:

1. **Tab title (ANSI)** — `tab-title.sh` writes `⏳ Claude Code | …`,
   `🔔 Claude Code | …`, `👀 Claude Code | …` (idle session with a live
   Claude-owned monitor — see "Watching state" below), `⚙️ Claude Code | …`
   (idle session with a live background Agent/Task/Workflow — see
   "Agents-running state" below), or the base title (no prefix) via
   `\033]2;<title>\007`. Primary user-visible signal. The menubar plugin
   uses the `binoculars` and `gearshape.fill` SF Symbols for the watching
   and agents-running states respectively (SF Symbols render better than
   emojis at menubar height); the tab title keeps the emoji prefixes
   because terminal ANSI titles render emojis reliably across UIs but
   can't reference SF Symbols.
2. **State files** — `tab-title.sh` also maintains one file per bell-state
   session at `~/.claude/bell-state/<session_id>`. The SwiftBar plugin
   reads this directory as its source of truth. Format:
   - Line 1: full tab title with icon prefix
   - Line 2: status string (`input` | `working` | `watching` | `idle`)
   - Line 3: the claude ancestor PID (stored for all write states).
     `sweep-bell-state.sh` uses it to prune orphaned files when the
     process has exited. The plugin also uses it for `watching` files
     to verify the monitored process is still alive on each poll.
3. **Push refresh** — on actual state transitions, `refresh-menubar.sh` fires
   `open -g swiftbar://refreshallplugins` so SwiftBar re-runs the plugin
   within a few hundred ms. The plugin's filename-encoded 30 s poll is a
   safety net, not the primary path.
4. **Event log + dashboard** — `tab-title.sh` also appends every transition
   to `~/.claude/.ccg/events.jsonl` (append-only JSONL: `{ts, session_id,
   state, title, cwd}`). The single-file dashboard at `~/.claude/.ccg/dashboard.html`
   fetches the log over HTTP every second and computes live + last-24h
   metrics. This layer is independent of bell mode — events are logged
   even when `notifs` mode suppresses bell-state writes for working/idle.

### Why state files instead of AppleScript tab enumeration

The macOS Accessibility API has a **30–60 second lag** reflecting ANSI-set tab
titles while Ghostty is backgrounded. An AppleScript-enumerating plugin made
the menubar feel 30 s+ behind reality. State files are visible to the plugin
within milliseconds, so the menubar updates in ~200 ms of a bell transition.
Diagnosed empirically via `BELL_TRACE` (see `/tmp/bell-trace.log` patterns
like `title-set` at T+0 but AppleScript `lines=0 bytes=0` at T+0, T+30s;
finally `lines=1` at T+60s).

### Why `refreshallplugins` vs `refreshplugin?name=…`

The plugin filename encodes its poll interval (`.30s.sh`), and users may
rename it (e.g. `.1m.sh`). `refreshallplugins` is resilient to that. The
externality (other SwiftBar plugins re-run) is negligible because we only
trigger on bell transitions — typically a few times a minute at most.

The rest of the state machine — watching state, agents-running state, the
pending-input set (and pre-bell state restore), the deferred completion
notification, refresh gating, event log dedup, stale-state cleanup (and its
dashboard-convergence and straggler-guard subtleties), the plugin's
` | ` → ` — ` display swap, and the dashboard's fleet-stall north-star
metric — is documented with full decision/why/rejected-alternative
rationale in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Read it before
changing any of `tab-title.sh`'s state-upgrade logic, `sweep-bell-state.sh`'s
reconciliation passes, `notify.sh`'s gating, or `dashboard.html`'s metrics.

## Scripts

`hooks/` contains scripts that are **installed globally** (`~/.claude/hooks/`).
`.claude/hooks/` contains scripts that are **project-local** (used only when
Claude runs in this repo, referenced from `.claude/settings.json`).

| Script | Purpose | Triggered by |
|--------|---------|--------------|
| `hooks/tab-title.sh` | Sets the terminal tab title via `terminalSequence` JSON output (Claude Code 2.1.141+) with a direct `/dev/tty` write as fallback; writes/removes `~/.claude/bell-state/<session_id>`; upgrades idle to `watching`/`agents` when a live monitor or background Agent/Task/Workflow is detected; appends real state transitions to `~/.claude/.ccg/events.jsonl`; fires `refresh-menubar.sh` on actual state change | `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `notify.sh` (for `input`) |
| `hooks/notify.sh` | Sends `terminal-notifier`; skips if user is already on that tab; routes to `tab-title.sh` for title updates; optional `gate=agents` 5th arg suppresses the notification while a background Agent/Task/Workflow subagent is still live for the session | `Notification`, `Stop` |
| `hooks/focus-ghostty-tab.sh` | AppleScript to focus a Ghostty tab by title-contains match; works across windows and single-tab windows | Notification `-execute`, SwiftBar dropdown |
| `hooks/refresh-menubar.sh` | `open -g swiftbar://refreshallplugins`; silent no-op if SwiftBar isn't installed | `tab-title.sh` on state change; `sweep-bell-state.sh` after pruning |
| `hooks/sweep-bell-state.sh` | Prunes bell-state files (dead PID, or >12 h); reconciles dead-but-unended sessions into `events.jsonl` via synthetic `end` events so the dashboard matches the menubar; fires a deferred "Background task completed" notification via `notify.sh` on the `agents → idle` logical-state edge | Background job dispatched by the SwiftBar plugin after each run |
| `.claude/hooks/fetch-changelog.sh` | Fetches `https://code.claude.com/docs/en/changelog`, strips HTML via `textutil`, caches to `~/.claude/.ccg/changelog.md` (12 h TTL) | `SessionStart` (project-only, via `.claude/settings.json`) |
| `hooks/dashboard-server.sh` | Manages the metrics-dashboard HTTP server (`start`/`stop`/`status`/`toggle`); writes `~/.claude/.ccg/server.pid` and opens browser on start | SwiftBar dropdown entry click |
| `swiftbar/ghostty-bells.30s.sh` | Reads state dir, emits dropdown (sessions + dashboard entry), dispatches sweep in background | SwiftBar 30 s poll + push-refresh URL |
| `.ccg/dashboard.html` | Single-file metrics dashboard; fetches `events.jsonl` over HTTP every second | Served via `python3 -m http.server` from `~/.claude/.ccg/` |
| `.ccg/config.json` | Mode config (`{"mode":"notifs|off|always-on"}`); shipped with `always-on` | Read by `tab-title.sh` and the SwiftBar plugin |
| `tests/validate.sh` | End-to-end validator; see below | Manual / CI |

## Environment variables

- **`BELL_TRACE=1`** — enables timestamped tracing in every script on the
  chain. Zero overhead when unset (each `__trace` function early-returns on
  the first line). Enable for a whole session by adding `"BELL_TRACE": "1"`
  under `env` in `~/.claude/settings.json`; for a one-off invocation, prefix
  the command: `BELL_TRACE=1 ~/.claude/hooks/tab-title.sh idle <session_id>`.
- **`BELL_TRACE_LOG`** — override the trace log path (default
  `/tmp/bell-trace.log`). The validator uses this to sandbox.
- **`BELL_STATE_DIR`** — override the state directory (default
  `~/.claude/bell-state`). The validator uses this to sandbox; production
  hooks don't set it.
- **`BELL_CONFIG`** — override the config-file path (default
  `~/.claude/.ccg/config.json`). The validator uses this to sandbox.
- **`CCG_EVENT_LOG`** — override the dashboard event log path (default
  `~/.claude/.ccg/events.jsonl`). The validator uses this to sandbox.
- **`CCG_SESSION_STATE_DIR`** — override the per-session logical-state
  directory used for event-log dedup (default `~/.claude/.ccg/sessions`).
  The validator uses this to sandbox.
- **`CCG_PENDING_DIR`** — override the pending-input set directory (default
  `~/.claude/.ccg/pending`). One subdir per session, one file per actor with
  an unanswered permission request; see "Pending-input set" above. The
  validator and `sweep-bell-state.sh` both honor it.
- **`CCG_NO_PID_STALE_MIN`** — staleness cap in minutes (default `30`) for
  state files that carry no claude PID, used by `sweep-bell-state.sh` for both
  the bell-state PID-liveness pass and the logical-state reconciliation no-PID
  fallback. A no-PID file untouched longer than this is reaped (menubar) /
  synthetically ended (dashboard). See "Stale-state cleanup".
- **`CCG_CLAUDE_PID`** — short-circuit the watching-detection walk in
  `tab-title.sh`. When set, `_find_claude_pid` returns this value
  immediately instead of walking up from `$PPID` looking for a `claude`
  ancestor. The validator sets it to `999999` (a dead PID) globally so
  no test accidentally walks up to the real claude process the validator
  is running under, and overrides it per-test in the watching section.
  Not used in production hook invocations.
- **`CCG_NOTIF_EXPIRY_HOURS`** — how many hours before a `ccg-*` macOS
  notification is auto-removed by `sweep-bell-state.sh` (default `12`). Set to
  `0` to disable expiry entirely.
- **`CCG_DIR`** — override the dashboard-server's working directory
  (default `~/.claude/.ccg`). Determines where the PID file and server
  log live, and the directory `python3 -m http.server` serves.
- **`CCG_DASHBOARD_PORT`** — override the dashboard server port (default
  `8765`).
- **`GHOSTTY_HOOKS_DIR`** — override the hooks directory path used by the
  SwiftBar plugin (default `~/.claude/hooks`).
- **`CCG_PROJECTS_DIR`** — override the Claude Code projects directory
  searched for subagent transcripts (default `~/.claude/projects`), used by
  `_count_live_agents` in both `tab-title.sh` and the SwiftBar plugin to
  detect background Agent/Task/Workflow liveness. The validator uses this to
  sandbox; production hooks don't set it.
- **`CCG_AGENTS_FRESH_SEC`** — freshness window in seconds (default `60`) for
  a background-agent transcript's mtime before `_count_live_agents` no longer
  counts it as live. See "Agents-running state".

## Validator

`tests/validate.sh` covers: prerequisites, state-file lifecycle,
title-write to parent's TTY (regression guard against the no-controlling-
terminal hook environment introduced in Claude Code 2.1.139), refresh
gating (fire vs skip), event-log dedup + JSON shape, `refresh-menubar.sh`
gate paths, plugin output (SF Symbol + count, param1 preservation,
` | ` → ` — ` swap, empty-dir hiding), dashboard-entry toggle (open/stop
based on PID file, stale-PID handling, position after sessions),
`dashboard-server.sh status` modes, stale-file sweep (hard-age prune
at 12 h, fresh files protected, PID-liveness prune for orphaned sessions,
fresh no-PID files kept but stale ones reaped past `NO_PID_STALE_MIN`,
refresh-after-prune), logical-state
reconciliation (a dead-PID session gets a synthetic `end` appended to
`events.jsonl` and its logical-state file removed; a live-PID session is
untouched; the synthetic `end` ts is the trailing-span cap `mtime + 30min`,
not `now`; stale no-PID files reaped past `NO_PID_STALE_MIN`; `tab-title.sh`
writes a 2-line state+pid logical-state file and dedup still keys off line 1),
watching state
(3-line state-file shape with claude PID on line 3 for all write states,
event log records `watching`, notifs mode suppresses the state file,
plugin downgrades stale watching files to idle, `Watching` section
ordered between `Working` and `Idle`), agents-running state (⚙️ prefix on
the state file, event log records `agents`, notifs mode suppresses the
state file, precedence over `watching` when both a fresh subagent
transcript and a live monitor marker are present, plugin downgrades a
stale-transcript agents file to idle, `Agents running` section ordered
between `Working` and `Watching`, the finishing agent's own
`SubagentStop` re-derives live state instead of sticking on the stale
logical-state value, and that re-derive excludes the finishing agent's OWN
transcript — which is still mtime-fresh at that exact instant — from the
liveness count, while a genuinely live sibling transcript still keeps the
state at `agents`), `BELL_TRACE` toggle (off = 0
bytes, on = populated), dashboard verdict logic (slices `verdictFor` from
`dashboard.html` by its `// <verdictFor>` markers and runs it under Node
across every branch + precedence boundary; asserts `renderVerdict` has a
`case` for each kind), dashboard straggler handling (slices
`stripStragglers` by its `// <stripStragglers>` markers and runs it under
Node: `end` is terminal so a post-`end` straggler or a tie-colliding synthetic
`end` reads as ended, while a fresh `idle` reopens a resumed session; asserts
all three per-session loops route through it), stray-working guard
(a stray `working` — subagent arriving after `idle`, or `__main__` arriving
after `end` deleted the logical-state file — must not resurrect `working`;
the main agent's start-of-turn `working` and a real mid-turn subagent `working`
both still pass through), pre-bell state restore (a bell that interrupts
`agents`/`watching` restores that refinement — re-derived live — instead of
defaulting to `working`; a second concurrent bell does not clobber the first
bell's snapshot; a bell interrupting plain `idle` or genuine mid-turn
`working` still defaults to/stays `working`; the snapshot file is consumed
on restore and cleared on `idle`/`end`), the notify.sh agents-gate (a live
subagent transcript suppresses the `gate=agents` notification entirely; a
stale or absent transcript lets it through; call sites that omit `gate`
are never suppressed even with a live transcript present), the deferred
completion notification (`sweep-bell-state.sh`'s logical-state
idle-refinement pass fires a `Background task completed` notification
specifically on the `agents → idle` edge, and does not fire one on
`watching → idle` or any other transition), and end-to-end
`input`→state→plugin latency.

It sandboxes via `BELL_STATE_DIR` pointing at a temp dir, so it never touches
real session state.

```sh
./tests/validate.sh            # failures + summary
./tests/validate.sh --verbose  # show every passing check
```

Exit code = number of failures. **Every code change must keep this passing,
and any new observable behavior must get a corresponding check.** If you
can't express the new behavior as a validator check, push back on the
change or lean on `BELL_TRACE` to make it observable first.

## Picking SF Symbols

When choosing an SF Symbol for the menubar (the SwiftBar plugin, status
icons, dashboard entries — anything rendered with `sfimage=…` or `:name:`
syntax), DEFAULT to rendering a temporary preview plugin so the user can
see all candidates rendered live in their menubar before deciding. Do not
ask the user to pick from a written list of names — SF Symbols don't read
the same way in prose as they do at menubar size, and the visual will
change the answer.

The temp-plugin pattern:

1. Drop a one-shot plugin into the **actual plugin directory** — the same
   directory the real plugin (`ghostty-bells.30s.sh`) already lives in
   (`~/swiftbar` on this machine; confirm with
   `defaults read com.ameba.SwiftBar PluginDirectory` if unsure — see the
   gotcha below, this is NOT `~/Library/Application Support/SwiftBar/`).
   Name it so it sorts AFTER the real plugin (e.g. `zzz-symbol-demo.5s.sh`)
   so the menubar stays mostly normal.
2. The plugin's title line should put every candidate side-by-side using
   the `:name:` shorthand, e.g.
   `echo "(picking) :eye: :binoculars: :waveform.path.ecg: :eye.circle: | font=.AppleSystemUIFontBold"`.
3. The dropdown should list each candidate with `sfimage=<name>` and a
   short description of when it'd fit, so the user can see each one
   rendered at dropdown size too.
4. Refresh SwiftBar (`open -g swiftbar://refreshallplugins`) and ask the
   user to look at the menubar.
5. AFTER the user picks, remove the demo plugin file (and any transient
   state files you wrote to make a real state visible) and refresh again.

Always offer at least 3–4 candidates including one that's a clear
thematic fit and one that's deliberately different in style (filled vs
outline, abstract vs literal), so the comparison is informative rather
than confirming a single guess.

## Gotchas

- **`/bin/bash` is 3.2.** The deployed scripts run under the kernel's
  interpretation of the `#!/bin/bash` shebang, which is the system bash.
  Avoid features from bash 4+. In particular, apostrophes inside quoted
  heredocs (`<<'EOF'`) confuse bash 3.2 — use `of AppleScript` instead of
  `AppleScript's`.
- **`pgrep -x Ghostty` is unreliable.** Ghostty's comm appears as `ghostty`
  (lowercase) but `pgrep -x` doesn't consistently match it on macOS. Use
  `osascript -e 'tell application "System Events" to return (exists process
  "Ghostty")'` instead.
- **SwiftBar's first-launch picker cannot be skipped.** The `defaults` key
  it actually reads is `PluginDirectory` (with security-scoped bookmark),
  not `PluginDirectoryPath`. Plain `defaults write` doesn't preseed it.
- **The SwiftBar plugin dir is `~/swiftbar`, not
  `~/Library/Application Support/SwiftBar/`.** The latter is SwiftBar's own
  app-support folder (it exists, is writable, and looks plausible) but
  SwiftBar never scans it for plugins — a script dropped there silently
  never appears. Always verify with
  `defaults read com.ameba.SwiftBar PluginDirectory` before writing a demo
  or real plugin file, rather than assuming the path.
- **Hooks can't `open -g` directly during rapid bursts.** All our hook-side
  `open` calls are synchronous (not backgrounded) so we get an exit code
  in trace; SwiftBar's URL-scheme dispatch is fast enough that this adds
  ~50 ms, not meaningful.
- **Menubar click still uses AX.** `focus-ghostty-tab.sh` relies on
  AppleScript, which has the AX lag. In practice the user clicks seconds
  after the bell appears, by which time Ghostty has been fronted enough for
  AX to update. If a click ever fails to find the tab, that's the reason.
