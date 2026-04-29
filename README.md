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

Create `~/.claude/cc-ghostty-config.json` to set the mode:

```json
{
  "mode": "always-on"
}
```

- **`mode`** — `"notifs"` (default) | `"off"` | `"always-on"`

## Validation

```sh
./tests/validate.sh            # test deployed scripts (~/.claude/hooks/)
./tests/validate.sh .          # test project scripts without deploying
./tests/validate.sh --verbose  # show every passing check
```

Runs ~68 end-to-end checks. Safe to run anytime (sandboxed temp directories). Exits non-zero on any failure.

## Why Ghostty

Ghostty uses native macOS tab groups, which are exposed to the accessibility framework. This lets AppleScript find and click tabs by title. Warp and Alacritty don't support this.

---

Contributors: see [CLAUDE.md](CLAUDE.md) for architecture, script reference, environment variables, and validator expectations.
