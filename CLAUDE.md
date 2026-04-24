# Agent / developer reference

This file is for anyone (human or agent) making code changes. End-user install
and usage live in `README.md`; everything architectural lives here.

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
5. **Local deploy** — ask the user whether the change should be copied to
   `~/.claude/hooks/` / `~/swiftbar/`.

## Architecture

Three layers cooperate:

1. **Tab title (ANSI)** — `tab-title.sh` writes `⏳ Claude Code | …`,
   `🔔 Claude Code | …`, or the base title (no prefix) via
   `\033]2;<title>\007`. Primary user-visible signal.
2. **State files** — `tab-title.sh` also maintains one file per bell-state
   session at `~/.claude/bell-state/<session_id>`, containing the 🔔-prefixed
   title. The SwiftBar plugin reads this directory as its source of truth.
3. **Push refresh** — on actual state transitions, `refresh-menubar.sh` fires
   `open -g swiftbar://refreshallplugins` so SwiftBar re-runs the plugin
   within a few hundred ms. The plugin's filename-encoded 30 s poll is a
   safety net, not the primary path.

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

### Refresh gating

`tab-title.sh` compares the desired state file against the on-disk state
file and only fires `refresh-menubar.sh` when something actually changed.
This is important because `PostToolUse` fires after every tool call and sets
status=working; without gating, every tool use would trigger a plugin refresh.
The gate:

- `input`: fire only if file didn't exist or content differs.
- `idle` / `working`: fire only if the file existed and was removed.
- `query`: never fires; read-only path.

### Stale-state cleanup

A session can end without firing `idle`/`working` — process killed, Ghostty
tab closed mid-prompt, macOS reboot while awaiting input. Its state file
would otherwise linger as a phantom dropdown entry. `sweep-bell-state.sh`
handles this in two passes:

1. **Hard age cap (24 h)** — unconditional delete. Works even when Ghostty
   isn't running and AX permissions are missing, so leftover state from a
   prior uptime is cleared on the next plugin run.
2. **AX-verified prune (5-min grace)** — for files past the grace period,
   query Ghostty's tab tree via AppleScript and delete any state file whose
   title isn't present. Grace period comfortably covers the AX lag above.
   Conservatively skipped if AX returns empty (Ghostty not running, no
   permission, transient error) — better to leave a phantom for one cycle
   than wrongly nuke a live bell.

The sweep is dispatched in the background by the plugin after it emits
output, so it never blocks menubar rendering. When it prunes anything, it
nudges SwiftBar so the dropdown reflects reality on the next run.

### Plugin display swap: ` | ` → ` — `

State file titles contain ` | ` (from `Claude Code | <dir>`). SwiftBar uses
` | ` as its parameter separator, so the plugin swaps to ` — ` in the
visible display text. `param1=` retains the original 🔔-prefixed title for
`focus-ghostty-tab.sh`'s contains-match.

## Scripts

| Script | Purpose | Triggered by |
|--------|---------|--------------|
| `hooks/tab-title.sh` | Sets the ANSI tab title; writes/removes `~/.claude/bell-state/<session_id>`; fires `refresh-menubar.sh` on actual state change | `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `notify.sh` (for `input`) |
| `hooks/notify.sh` | Sends `terminal-notifier`; skips if user is already on that tab; routes to `tab-title.sh` for title updates | `Notification`, `Stop` |
| `hooks/focus-ghostty-tab.sh` | AppleScript to focus a Ghostty tab by title-contains match; works across windows and single-tab windows | Notification `-execute`, SwiftBar dropdown |
| `hooks/refresh-menubar.sh` | `open -g swiftbar://refreshallplugins`; silent no-op if SwiftBar isn't installed | `tab-title.sh` on state change; `sweep-bell-state.sh` after pruning |
| `hooks/sweep-bell-state.sh` | Prunes stale state files (hard-age + AX-verified) | Background job dispatched by the SwiftBar plugin after each run |
| `swiftbar/ghostty-bells.30s.sh` | Reads state dir, emits dropdown, dispatches sweep in background | SwiftBar 30 s poll + push-refresh URL |
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
- **`GHOSTTY_HOOKS_DIR`** — override the hooks directory path used by the
  SwiftBar plugin (default `~/.claude/hooks`).

## Validator

`tests/validate.sh` runs ~43 checks covering: prerequisites, state-file
lifecycle, refresh gating (fire vs skip), `refresh-menubar.sh` gate paths,
plugin output (SF Symbol + count, param1 preservation, ` | ` → ` — ` swap,
empty-dir hiding), stale-file sweep (hard age, grace protection, AX-verified
prune, refresh-after-prune), `BELL_TRACE` toggle (off = 0 bytes, on =
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
