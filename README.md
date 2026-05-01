# Ghostty + Claude Code: Tab-Targeted Notifications

When running multiple Claude Code agents in Ghostty tabs, clicking a notification activates Ghostty and focuses the correct tab. Tab titles show the agent's state at a glance. An optional menubar indicator tracks sessions.

## How It Works

Each session's tab title encodes its state:

- `⏳ Claude Code | …` — working
- `🔔 Claude Code | …` — awaiting input
- `Claude Code | <dir> (<shortID>)` — idle (or `Claude Code | <summary>` if `/rename`d)

Notifications use `terminal-notifier` with an `-execute` script that finds and clicks the matching tab by partial title match, so it works across windows and tab reorders. Ghostty's native notifications are disabled to avoid duplicates.

## Prerequisites

- macOS
- [Ghostty](https://ghostty.org/) (`brew install --cask ghostty`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `brew install jq terminal-notifier coreutils`
- Grant accessibility permissions to `terminal-notifier` and `osascript` (System Settings > Privacy & Security > Accessibility)

## Installation

### 1. Copy hook scripts

```sh
mkdir -p ~/.claude/hooks
cp hooks/* ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
```

### 2. Configure Claude Code settings

```sh
cp settings.json ~/.claude/settings.json
```

If you already have a `~/.claude/settings.json`, merge the `env` and `hooks` keys manually.

### 3. Configure Ghostty

Add to `~/Library/Application Support/com.mitchellh.ghostty/config`:

```
desktop-notifications = false
```

This avoids duplicate notifications and prevents Ghostty from yanking the whole window across desktops. Optionally also add:

```
bell-features = no-title
```

to disable Ghostty's native bell icon in non-Claude tabs (our notifications handle that signaling).

### 4. Grant accessibility permissions

macOS will prompt on first use for `terminal-notifier` and `osascript`. Grant both in System Settings > Privacy & Security > Accessibility. Notification click-to-navigate won't work without this.

## Optional: menubar indicator

A [SwiftBar](https://swiftbar.app/) plugin shows a menubar indicator for Claude Code sessions. Three modes are available; the default (`notifs`) requires no configuration.

1. `brew install --cask swiftbar`
2. Create a plugins directory:

   ```sh
   mkdir -p ~/swiftbar
   ```

3. Launch SwiftBar (`open -a SwiftBar`). On first launch it opens a folder picker; select the directory you just created.
4. Copy the plugin:

   ```sh
   cp swiftbar/ghostty-bells.30s.sh ~/swiftbar/
   chmod +x ~/swiftbar/ghostty-bells.30s.sh
   ```

   SwiftBar auto-detects new plugin files. The `.30s` in the filename is a background poll interval; rename to tune it (e.g. `.1m.sh`). Live transitions update the menubar within ~200 ms via push refresh.

### Menubar modes

| Mode | Behavior |
|------|----------|
| `notifs` (default) | Hidden when all sessions are idle or working; shows a bell icon + count when one or more sessions are awaiting input |
| `off` | Always hidden even if the plugin is installed |
| `always-on` | Always visible; shows counts for all session states; emoji bell appears in header (yellow) when any session needs input |

**`always-on` example** — when one session awaits input and two others are active:

```
🔔 1 ⏳ 1 💤 1   ← bold numbers; emoji bell when any session awaits input
─────────────────────
Awaiting input
  🔔 api-service (a1b2c3d4)
─────────────────────
Working
  ⏳ frontend (e5f6a7b8)
─────────────────────
Idle
  💤 devtools (c9d0e1f2)
```

When no sessions are awaiting input the header shows only `⏳ N 💤 N` (no bell). Clicking any entry focuses that Ghostty tab.

### Configuration

Configuration and dashboard artifacts live under `~/.claude/.ccg/`. Set the mode by creating `~/.claude/.ccg/config.json`:

```sh
mkdir -p ~/.claude/.ccg
cp .ccg/config.json ~/.claude/.ccg/config.json    # ships with {"mode":"always-on"}
```

```json
{
  "mode": "always-on"
}
```

- **`mode`** — `"notifs"` (default) | `"off"` | `"always-on"`

## Optional: metrics dashboard

The hooks log every state transition to `~/.claude/.ccg/events.jsonl` (append-only JSONL). A self-contained dashboard reads this log and shows live + last-24h metrics: concurrent working / awaiting / idle right now, time spent in each state, sessions started, average response latency (🔔 → next prompt), and peak concurrent working.

1. Copy the dashboard:

   ```sh
   mkdir -p ~/.claude/.ccg
   cp .ccg/dashboard.html ~/.claude/.ccg/
   ```

2. Open it. Two ways:

   - **From the SwiftBar dropdown** (recommended) — the menubar plugin appends an **Open dashboard** entry below the session list. Click it: the plugin starts `python3 -m http.server 8765` from `~/.claude/.ccg/` and opens http://localhost:8765/dashboard.html. The entry then becomes **Stop dashboard server**.

   - **Manually** — the dashboard fetches `events.jsonl` over HTTP and refuses to run from `file://`:

     ```sh
     cd ~/.claude/.ccg
     python3 -m http.server 8765
     ```

     Then open http://localhost:8765/dashboard.html.

3. The dashboard auto-refreshes every second.

The dashboard is a single HTML file that imports Chart.js from a CDN; there are no build steps and no other files to install. The PID of the running server is tracked at `~/.claude/.ccg/server.pid` so the menubar entry stays in sync across SwiftBar refreshes.

## Validation

```sh
./tests/validate.sh            # test deployed scripts (~/.claude/hooks/)
./tests/validate.sh .          # test project scripts without deploying
./tests/validate.sh --verbose  # show every passing check
```

Runs ~99 end-to-end checks. Safe to run anytime (sandboxed temp directories). Exits non-zero on any failure.

## Why Ghostty

Ghostty uses native macOS tab groups, which are exposed to the accessibility framework. This lets AppleScript find and click tabs by title. Warp and Alacritty don't support this.

---

Contributors: see [CLAUDE.md](CLAUDE.md) for architecture, script reference, environment variables, and validator expectations.
