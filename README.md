# Ghostty + Claude Code: Tab-Targeted Notifications

When running multiple Claude Code agents in Ghostty tabs, clicking a notification activates Ghostty and focuses the correct tab. Tab titles show the agent's state at a glance.

## How It Works

1. Each session gets a stable tab title: `Claude Code | <directory> (<shortID>)` (or `Claude Code | <summary>` if `/rename`d)
2. When working: `⏳ Claude Code | ...`
3. When waiting for permission: `🔔 Claude Code | ...`
4. When finished: back to `Claude Code | ...`
5. Notifications use `terminal-notifier` with an `-execute` script that finds and clicks the matching tab (partial title match). Since tabs are targeted by title rather than index, this works even if tabs are reordered or moved between windows
6. Ghostty's native notifications are disabled to avoid duplicates

## Prerequisites

- macOS
- [Ghostty](https://ghostty.org/) (`brew install --cask ghostty`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `brew install jq terminal-notifier`
- Grant accessibility permissions to `terminal-notifier` and `osascript` (System Settings > Privacy & Security > Accessibility)

## Installation

### 1. Copy hook scripts

Copy all scripts from the `hooks/` directory in this repo to `~/.claude/hooks/` and make them executable:

```sh
mkdir -p ~/.claude/hooks
cp hooks/* ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
```

### 2. Configure Claude Code settings

Merge the contents of `settings.json` from this repo into your `~/.claude/settings.json`. If you don't have a settings file yet, you can copy it directly:

```sh
cp settings.json ~/.claude/settings.json
```

If you already have a `~/.claude/settings.json`, manually merge the `env` and `hooks` keys from `settings.json` into your existing file.

### 3. Configure Ghostty

Add the following line to your Ghostty config file at `~/Library/Application Support/com.mitchellh.ghostty/config`:

```
desktop-notifications = false
```

Ghostty's native notifications bring the entire window to the current desktop instead of switching to Ghostty's desktop. Our custom `terminal-notifier` hook avoids this. Disabling native notifications prevents duplicates.

Optionally, also add:

```
bell-features = no-title
```

This disables the native bell icon that Ghostty shows in non-Claude tabs when a notification fires, since our custom notifications handle that signaling.

### 4. Grant accessibility permissions

On first use, macOS will prompt for accessibility permissions for `terminal-notifier` and `osascript`. Grant these in System Settings > Privacy & Security > Accessibility. Notification click-to-navigate won't work without this.

## Repo Contents

### `settings.json`

Claude Code settings containing the `env` and `hooks` configuration needed for this setup. The `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` env var prevents Claude Code from overwriting the custom tab titles.

If you `/rename` a session, the custom name replaces the short ID in the tab title (e.g., `⏳ Claude Code | my-task`). This is read from the session's jsonl file by `tab-title.sh`.

### `hooks/`

All hook scripts. Must be in `~/.claude/hooks/` and executable.

| Script | Purpose |
|--------|---------|
| `tab-title.sh` | Unified tab title manager. Called directly from `settings.json` with a status argument (`idle`, `working`, `input`, `query`). Reads `session_id` from stdin JSON (or accepts it as a second argument). Sets the terminal title with the appropriate status icon and appends the session summary if one exists (from `/rename`). Outputs two lines to stdout: the base title and the summary |
| `notify.sh` | Sends a macOS notification via `terminal-notifier`. Called directly from `settings.json` with arguments for icon, default message, tab status, and notification type filter. Skipped if the user is already looking at this tab. On click, runs `focus-ghostty-tab.sh` |
| `focus-ghostty-tab.sh` | Activates Ghostty and focuses the tab whose title contains the given string. Works across multiple windows and single-tab windows |

## Why Ghostty

Ghostty uses native macOS tab groups, which are exposed to the accessibility framework. This lets AppleScript find and click tabs by title. Warp and Alacritty don't support this.
