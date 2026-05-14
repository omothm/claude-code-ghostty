# Agent / developer reference

This file is for anyone (human or agent) making code changes. End-user install
and usage live in `README.md`; everything architectural lives here.

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
2. **Tab targeting** — will notifications still focus the correct tab?
   `focus-ghostty-tab.sh` uses contains-match against AX tab titles; confirm
   the title stored in state files and passed via `terminal-notifier` still
   uniquely identifies the session.
3. **Notification text** — does any user-visible string need updating?
4. **README.md** — does the human-facing documentation still reflect the
   current install flow? (Architecture details don't belong there.)
5. **Dashboard** — open `.ccg/dashboard.html` and inspect every place that
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
6. **Hook parity** — `settings.json` (project) and `~/.claude/settings.json`
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
7. **Local deploy** — ask the user whether the change should be copied to
   `~/.claude/hooks/` / `~/swiftbar/` / `~/.claude/.ccg/`.
8. **Commit and push** — every change ends with a commit and a push to
   *all* configured remotes (this overrides the default "only commit
   when explicitly asked" rule for this repo). Don't wait for the user
   to ask. Remotes to push to are whatever `git remote` lists; today
   that's `origin` and `trilogy`. Push to each one in sequence.
   **For bug fixes: do not commit until the fix is proven working** —
   hold the commit until the user confirms the fix is behaving correctly
   in practice. Once confirmed, commit and push immediately without
   asking.

## Architecture

Four layers cooperate:

1. **Tab title (ANSI)** — `tab-title.sh` writes `⏳ Claude Code | …`,
   `🔔 Claude Code | …`, `👀 Claude Code | …` (idle session with a live
   Claude-owned monitor — see "Watching state" below), or the base title
   (no prefix) via `\033]2;<title>\007`. Primary user-visible signal.
   The menubar plugin uses the `binoculars` SF Symbol for the same state
   (SF Symbols render better than emojis at menubar height); the tab
   title keeps the 👀 emoji because terminal ANSI titles render emojis
   reliably across UIs but can't reference SF Symbols.
2. **State files** — `tab-title.sh` also maintains one file per bell-state
   session at `~/.claude/bell-state/<session_id>`. The SwiftBar plugin
   reads this directory as its source of truth. Format:
   - Line 1: full tab title with icon prefix
   - Line 2: status string (`input` | `working` | `watching` | `idle`)
   - Line 3: only present for `watching` — the claude ancestor PID, used
     by the plugin to verify the monitor is still alive on each poll.
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

### Watching state

A session in `idle` state is upgraded to `watching` when the `claude`
ancestor process still has at least one live child whose command line
contains the `/tmp/claude-<hex>-cwd` marker. That marker is emitted by
Claude Code's bash-tool wrapper, so it's present on synchronous Bash
calls, `Bash(run_in_background: true)` shells, and the `Monitor` tool's
long-running background command. Synchronous calls exit in seconds, so
any match while the session has reported idle is a live Monitor or
background bash — work the user should "keep an eye on."

Detection happens entirely in `tab-title.sh`'s `idle` branch:

1. Walk up from `$PPID` (max 8 hops) looking for a process whose `comm`
   is `claude`. The hook's invocation chain is usually `claude → shell →
   tab-title.sh`, so this lands in 1–2 hops. The `CCG_CLAUDE_PID` env
   var short-circuits the walk (used by the validator to point at a PID
   it owns).
2. Run `ps -axo ppid=,command=` and awk-count immediate children of that
   PID whose command matches `/\/tmp\/claude-[0-9a-f]+-cwd/`.
3. If the count is >0, treat the effective status as `watching` for
   title, state file, and event log.

Stale watching is handled in the plugin, not the hook: when the plugin
reads a `watching` state file it `kill -0`s line 3 (the claude PID) and
re-runs the awk count, downgrading to `idle` in memory if either check
fails. This lets a session reflect a monitor that exited *after* `Stop`
fired — there's no hook for that transition, so polling on each plugin
run is the only way the dropdown can stay honest.

Sub-agent (`Task` tool) monitors are not detected — they're children of
a *sub-agent* claude PID, not the main session's. If you need to extend
this, change `_count_live_monitors` to a transitive descendant walk.
Immediate children covers Monitor and `run_in_background` for the main
session, which is the common case.

### Refresh gating

`tab-title.sh` compares the desired state file against the on-disk state
file and only fires `refresh-menubar.sh` when something actually changed.
This is important because `PostToolUse` fires after every tool call and sets
status=working; without gating, every tool use would trigger a plugin refresh.
The gate:

- `input`: fire only if file didn't exist or content differs.
- `idle` / `working`: fire only if the file existed and was removed.
- `query`: never fires; read-only path.

### Event log dedup

`events.jsonl` must record real transitions only — `PostToolUse` fires after
every tool call, so a naive append would flood the log. `tab-title.sh`
keeps a per-session "logical state" file at `~/.claude/.ccg/sessions/<sid>`
(content: just the state name) and only appends to `events.jsonl` when the
new state differs from that file. On `end`, the per-session file is removed
so a future `SessionStart` for the same `session_id` would re-emit `idle`.
A pure `end` with no prior state is dropped to avoid zombie entries from
stray hook invocations.

This layer is intentionally independent of bell mode: in `notifs` mode the
bell-state file isn't written for `idle`/`working`, but the event log still
gets every transition. Sandbox via `CCG_EVENT_LOG` and
`CCG_SESSION_STATE_DIR` env vars (the validator does this).

### Stale-state cleanup

A session can end without firing `end` — process killed, Ghostty tab
closed mid-prompt, macOS reboot while the SessionEnd hook is mid-flight.
Its state file would otherwise linger as a phantom dropdown entry.
`sweep-bell-state.sh` handles this with a single hard-age pass: any state
file older than 12 h is deleted unconditionally. The graceful path is the
SessionEnd hook calling `tab-title.sh end`, which removes the file the
moment a session exits cleanly; the sweep only matters for crashes and
similar irregular exits.

An earlier version of the sweep also ran an "AX-verified" pass that
queried Ghostty's tab tree via AppleScript and pruned any state file
whose title was missing. We removed it because the AppleScript query
races with Ghostty's own tab-bar redraws and intermittently returns
partial tab lists (empirically, ~14% of queries omit a tab; ~1% omit
multiple). That made the pass spuriously delete state files for live
idle sessions, so the menubar would silently lose entries over time.
The 12 h cap is the trade-off: phantoms can linger up to 12 h, but
real sessions are never wrongly evicted.

The sweep is dispatched in the background by the plugin after it emits
output, so it never blocks menubar rendering. When it prunes anything, it
nudges SwiftBar so the dropdown reflects reality on the next run.

### Plugin display swap: ` | ` → ` — `

State file titles contain ` | ` (from `Claude Code | <dir>`). SwiftBar uses
` | ` as its parameter separator, so the plugin swaps to ` — ` in the
visible display text. `param1=` retains the original 🔔-prefixed title for
`focus-ghostty-tab.sh`'s contains-match.

## Scripts

`hooks/` contains scripts that are **installed globally** (`~/.claude/hooks/`).
`.claude/hooks/` contains scripts that are **project-local** (used only when
Claude runs in this repo, referenced from `.claude/settings.json`).

| Script | Purpose | Triggered by |
|--------|---------|--------------|
| `hooks/tab-title.sh` | Sets the terminal tab title via `terminalSequence` JSON output (Claude Code 2.1.141+) with a direct `/dev/tty` write as fallback; writes/removes `~/.claude/bell-state/<session_id>`; appends real state transitions to `~/.claude/.ccg/events.jsonl`; fires `refresh-menubar.sh` on actual state change | `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `notify.sh` (for `input`) |
| `hooks/notify.sh` | Sends `terminal-notifier`; skips if user is already on that tab; routes to `tab-title.sh` for title updates | `Notification`, `Stop` |
| `hooks/focus-ghostty-tab.sh` | AppleScript to focus a Ghostty tab by title-contains match; works across windows and single-tab windows | Notification `-execute`, SwiftBar dropdown |
| `hooks/refresh-menubar.sh` | `open -g swiftbar://refreshallplugins`; silent no-op if SwiftBar isn't installed | `tab-title.sh` on state change; `sweep-bell-state.sh` after pruning |
| `hooks/sweep-bell-state.sh` | Prunes state files older than 12 h | Background job dispatched by the SwiftBar plugin after each run |
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
- **`CCG_CLAUDE_PID`** — short-circuit the watching-detection walk in
  `tab-title.sh`. When set, `_find_claude_pid` returns this value
  immediately instead of walking up from `$PPID` looking for a `claude`
  ancestor. The validator sets it to `999999` (a dead PID) globally so
  no test accidentally walks up to the real claude process the validator
  is running under, and overrides it per-test in the watching section.
  Not used in production hook invocations.
- **`CCG_DIR`** — override the dashboard-server's working directory
  (default `~/.claude/.ccg`). Determines where the PID file and server
  log live, and the directory `python3 -m http.server` serves.
- **`CCG_DASHBOARD_PORT`** — override the dashboard server port (default
  `8765`).
- **`GHOSTTY_HOOKS_DIR`** — override the hooks directory path used by the
  SwiftBar plugin (default `~/.claude/hooks`).

## Validator

`tests/validate.sh` covers: prerequisites, state-file lifecycle,
title-write to parent's TTY (regression guard against the no-controlling-
terminal hook environment introduced in Claude Code 2.1.139), refresh
gating (fire vs skip), event-log dedup + JSON shape, `refresh-menubar.sh`
gate paths, plugin output (SF Symbol + count, param1 preservation,
` | ` → ` — ` swap, empty-dir hiding), dashboard-entry toggle (open/stop
based on PID file, stale-PID handling, position after sessions),
`dashboard-server.sh status` modes, stale-file sweep (hard-age prune
at 12 h, fresh files protected, refresh-after-prune), watching state
(3-line state-file shape with claude PID on line 3, event log records
`watching`, notifs mode suppresses the state file, plugin downgrades
stale watching files to idle, `Watching` section ordered between
`Working` and `Idle`), `BELL_TRACE` toggle (off = 0 bytes, on =
populated), and end-to-end `input`→state→plugin latency.

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

1. Drop a one-shot plugin into the SwiftBar dir with a name that sorts
   AFTER the real plugin (e.g. `zzz-symbol-demo.5s.sh`) so the menubar
   stays mostly normal.
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
- **Hooks can't `open -g` directly during rapid bursts.** All our hook-side
  `open` calls are synchronous (not backgrounded) so we get an exit code
  in trace; SwiftBar's URL-scheme dispatch is fast enough that this adds
  ~50 ms, not meaningful.
- **Menubar click still uses AX.** `focus-ghostty-tab.sh` relies on
  AppleScript, which has the AX lag. In practice the user clicks seconds
  after the bell appears, by which time Ghostty has been fronted enough for
  AX to update. If a click ever fails to find the tab, that's the reason.
