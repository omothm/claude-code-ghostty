# Ghostty + Claude Code: Tab-Targeted Notifications

When running multiple Claude Code agents in Ghostty tabs, clicking a notification activates Ghostty and focuses the correct tab. Tab titles show the agent's state at a glance. An optional menubar indicator lists every session currently awaiting input.

## How It Works

Each session's tab title encodes its state:

- `⏳ Claude Code | …` — working
- `🔔 Claude Code | …` — waiting for permission
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

## Optional: menubar bell indicator

A [SwiftBar](https://swiftbar.app/) plugin shows a menubar icon when one or more Claude Code sessions are awaiting input, with a dropdown to focus any of them. Entirely optional — the core notifications above work without it.

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

## Validation

```sh
./tests/validate.sh
```

Runs ~43 end-to-end checks against the deployed scripts. Safe to run anytime (sandboxed). Exits non-zero on any failure.

## Why Ghostty

Ghostty uses native macOS tab groups, which are exposed to the accessibility framework. This lets AppleScript find and click tabs by title. Warp and Alacritty don't support this.

---

Contributors: see [CLAUDE.md](CLAUDE.md) for architecture, script reference, environment variables, and validator expectations.
