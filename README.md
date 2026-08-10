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
| `❓ Claude Code \| …` | Waiting for you to answer a question (AskUserQuestion) |
| `☕️ Claude Code \| …` | Idle, but a background Agent/Task/Workflow is still running |
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

The menubar icon shows live session counts. Clicking any entry focuses that tab. Each entry shows a muted last-update time, and within each section the longest-idle tab is listed first — so the session you're most likely to have forgotten about is always at the top. Three modes control when the icon appears:

| Mode | Behavior |
|---|---|
| `always-on` (default) | Always visible; shows counts for all states |
| `notifs` | Hidden when all sessions are idle or working; appears when a session needs input |
| `off` | Always hidden |

Change the mode by editing `~/.claude/.ccg/config.json`:

```json
{ "mode": "notifs" }
```

### 5h-limit pace indicator

The menubar can show a live ahead/behind indicator for Anthropic's 5-hour rate limit — how far you are from the rate at which you'd need to consume to exhaust the window exactly at reset time.

**To enable:** click **Show 5h Pace** in the SwiftBar dropdown (checkbox, unchecked by default). Or set `"show5hPace": true` in `~/.claude/.ccg/config.json`. The checkbox's subtitle always shows `Reset: HH:MM, STATE` (muted gray) — the reset time and current pace state — even while the toggle itself is off, so you can preview it before enabling the header segment.

The indicator appears at the very right of the existing counters in the menubar header (always-on mode only). Example output:

| Display | Meaning |
|---|---|
| `45%←12m🔥` | 45% used, but you're **12 minutes ahead** of linear pace — consuming slower than the clock (🔥 calls attention) |
| `45%→8m` | 45% used, **8 minutes behind** — consuming faster than the clock (normal cruising case) |
| `45%` | Exactly on pace |

🔥 marks the "ahead of pace" case, where you have headroom: you could consume more before the reset and still stay under the limit.

**Data source:** the plugin reads `~/.claude/.ccg/rate-limits-cache.json` (configurable via `"rateLimitsCacheFile"` in `config.json`). This file must be written by your statusline renderer or any other hook that receives the Claude Code session JSON. The plugin ignores absent values gracefully — if the file doesn't exist or the key is missing, the indicator is simply not shown.

The cache file must contain at minimum:

```json
{
  "five_hour": {
    "used_percentage": 45.2,
    "resets_at": 1754321000
  }
}
```

`resets_at` is a Unix timestamp (seconds). `used_percentage` is 0–100.

**Example: writing the cache from a statusline command** (add to your `~/.claude/statusline-command.sh`):

```sh
# Write 5h rate-limit data for the SwiftBar pace indicator
five_h_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
if [ -n "$five_h_pct" ] && [ -n "$five_h_reset" ]; then
  jq -cn \
    --argjson pct "$five_h_pct" \
    --argjson reset "$five_h_reset" \
    '{five_hour:{used_percentage:$pct,resets_at:$reset}}' \
    > "$HOME/.claude/.ccg/rate-limits-cache.json" 2>/dev/null
fi
```

`input` here is the JSON Claude Code writes to your statusline command's stdin (i.e. `input=$(cat)` at the top of the script).

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
