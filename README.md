# Ghostty + Claude Code: Smart Notifications

Running multiple Claude Code sessions in Ghostty tabs? This gives you three things:

- **Clickable notifications** — clicking a notification focuses the exact Ghostty tab that needs your attention, not just the app
- **Tab titles that show session state** — glance at your tab bar and know which agents are working, waiting, or idle
- **An optional menubar indicator** — a SwiftBar plugin that shows session counts and a one-click jump to any session, without leaving your current app

## Install

```sh
git clone https://github.com/omothm/claude-code-ghostty
cd claude-code-ghostty
./install.sh
```

Then add two lines to your Ghostty config (`~/Library/Application Support/com.mitchellh.ghostty/config`):

```
desktop-notifications = false
bell-features = no-title
```

The first disables Ghostty's own notifications (which would duplicate ours). The second disables Ghostty's native bell icon in non-Claude tabs.

To update: `git pull && ./install.sh`. The script is idempotent — it only touches what has changed.

## Prerequisites

- macOS
- [Ghostty](https://ghostty.org/) (`brew install --cask ghostty`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `brew install jq terminal-notifier coreutils`
- Accessibility permissions for `terminal-notifier` and `osascript` (macOS will prompt on first use; grant in System Settings > Privacy & Security > Accessibility)

## What you get

**Tab titles** always show each session's state:

| Title prefix | Meaning |
|---|---|
| `⏳ Claude Code \| …` | Working |
| `🔔 Claude Code \| …` | Waiting for your input |
| `👀 Claude Code \| …` | Idle, but a background task is still running |
| `Claude Code \| <dir>` | Idle |

**Notifications** fire when a session completes a task or needs your input. The notification's `-execute` action focuses the exact tab by partial title match — works across windows and regardless of tab order.

## Optional: menubar indicator

Install [SwiftBar](https://swiftbar.app/) and the install script deploys the plugin automatically.

```sh
brew install --cask swiftbar
mkdir -p ~/swiftbar
open -a SwiftBar  # pick ~/swiftbar as the plugins directory on first launch
./install.sh      # deploys the plugin
```

The menubar icon shows live session counts. Clicking any entry focuses that tab. Three modes control when the icon appears:

| Mode | Behavior |
|---|---|
| `always-on` (default) | Always visible; shows counts for all states |
| `notifs` | Hidden when all sessions are idle or working; appears when a session needs input |
| `off` | Always hidden |

Change the mode by editing `~/.claude/.ccg/config.json`:

```json
{ "mode": "notifs" }
```

## Optional: metrics dashboard

The hooks log every state transition to `~/.claude/.ccg/events.jsonl`. A self-contained dashboard reads this log and shows live and last-24h metrics: sessions active, time in each state, average response latency, and peak concurrency.

If the SwiftBar plugin is installed, click **Open dashboard** in the menubar dropdown — it starts a local HTTP server and opens the dashboard automatically.

To open it manually:

```sh
cd ~/.claude/.ccg
python3 -m http.server 8765
# then open http://localhost:8765/dashboard.html
```

## Why Ghostty

Ghostty exposes its tab bar through the macOS Accessibility API, which lets AppleScript find and click a tab by title. Warp and Alacritty don't support this, so the click-to-navigate notification action only works with Ghostty.

---

Contributors: see [CLAUDE.md](CLAUDE.md) for architecture, scripts, environment variables, and validator usage.
