#!/bin/bash
# install.sh — install or update claude-code-ghostty
# Idempotent: safe to re-run; only applies changes that are out-of-date.
# Run again after `git pull` to pick up updates.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
CCG_DIR="${CCG_DIR:-$HOME/.claude/.ccg}"
SETTINGS="$HOME/.claude/settings.json"
SWIFTBAR_DIR="${SWIFTBAR_PLUGIN_DIR:-$HOME/swiftbar}"

# ── sanity checks ─────────────────────────────────────────────────────────────

if [ ! -f "$REPO/hooks/tab-title.sh" ] || [ ! -f "$REPO/settings.json" ]; then
  printf 'Error: run this script from the claude-code-ghostty repository root.\n' >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  printf 'Error: jq is required. Install with: brew install jq\n' >&2
  exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────

changes=0
_changed() { printf '  \342\234\223 %s\n' "$1"; changes=$((changes + 1)); }  # ✓
_skip()    { printf '  \302\267 %s\n' "$1"; }                                 # ·

# Copy src → dst only if contents differ (or dst is missing).
# Returns 0 if copied, 1 if already identical.
_copy_if_changed() {
  [ -f "$2" ] && cmp -s "$1" "$2" && return 1
  cp "$1" "$2"
}

# Returns 0 if hook event $1 already contains a command matching pattern $2.
_has_hook() {
  jq -e --arg e "$1" --arg p "$2" \
    '[(.hooks[$e] // []) | .[].hooks[]?.command // ""] | any(contains($p))' \
    "$SETTINGS" > /dev/null 2>&1
}

# Appends our hook group for event $1 from settings.json to the user's settings file.
_add_hook() {
  local event="$1" our_hooks tmp
  our_hooks=$(jq --arg e "$event" '.hooks[$e]' "$REPO/settings.json")
  tmp=$(mktemp)
  jq --arg e "$event" --argjson h "$our_hooks" \
    '.hooks[$e] = ((.hooks[$e] // []) + $h)' \
    "$SETTINGS" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$SETTINGS"
}

# Check-and-add a single hook event. $1 = event name, $2 = command pattern to detect.
_check_hook() {
  if _has_hook "$1" "$2"; then
    _skip "$1 hook"
  else
    _add_hook "$1"
    _changed "$1 hook"
  fi
}

# ── 1. hook scripts ───────────────────────────────────────────────────────────

printf 'Hooks:\n'
mkdir -p "$HOOKS_DIR"
for src in "$REPO/hooks/"*.sh; do
  name=$(basename "$src")
  if _copy_if_changed "$src" "$HOOKS_DIR/$name"; then
    chmod +x "$HOOKS_DIR/$name"
    _changed "$name"
  else
    _skip "$name"
  fi
done

# ── 2. ~/.claude/settings.json ────────────────────────────────────────────────

printf 'Settings:\n'
mkdir -p "$(dirname "$SETTINGS")"

if [ ! -f "$SETTINGS" ]; then
  cp "$REPO/settings.json" "$SETTINGS"
  _changed "~/.claude/settings.json (created)"
else
  # env key
  if [ "$(jq -r '.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE // ""' "$SETTINGS")" != "1" ]; then
    tmp=$(mktemp)
    jq '.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE = "1"' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    _changed "CLAUDE_CODE_DISABLE_TERMINAL_TITLE env var"
  else
    _skip "CLAUDE_CODE_DISABLE_TERMINAL_TITLE env var"
  fi

  # hook events — detect by the script name used in each event's commands
  _check_hook "SessionStart"      "tab-title.sh"
  _check_hook "PermissionRequest" "notify.sh"
  _check_hook "UserPromptSubmit"  "tab-title.sh"
  _check_hook "PostToolUse"       "tab-title.sh"
  _check_hook "Stop"              "tab-title.sh"
  _check_hook "StopFailure"       "tab-title.sh"
  _check_hook "SessionEnd"        "tab-title.sh"
fi

# ── 3. CCG directory and files ────────────────────────────────────────────────

printf 'Dashboard:\n'
mkdir -p "$CCG_DIR"

# config.json: preserve any user customizations (only create if absent)
if [ ! -f "$CCG_DIR/config.json" ]; then
  cp "$REPO/.ccg/config.json" "$CCG_DIR/config.json"
  _changed "config.json (mode: always-on)"
else
  _skip "config.json (preserved)"
fi

# dashboard.html: always keep current (not user-customizable)
if _copy_if_changed "$REPO/.ccg/dashboard.html" "$CCG_DIR/dashboard.html"; then
  _changed "dashboard.html"
else
  _skip "dashboard.html"
fi

# ── 4. SwiftBar plugin (optional) ─────────────────────────────────────────────

printf 'SwiftBar:\n'
if [ -d "$SWIFTBAR_DIR" ]; then
  dst="$SWIFTBAR_DIR/ghostty-bells.30s.sh"
  if _copy_if_changed "$REPO/swiftbar/ghostty-bells.30s.sh" "$dst"; then
    chmod +x "$dst"
    _changed "ghostty-bells.30s.sh"
  else
    _skip "ghostty-bells.30s.sh"
  fi
else
  _skip "not installed (~/swiftbar not found — optional, see README)"
fi

# ── 5. Ghostty config reminder (manual step) ─────────────────────────────────

GHOSTTY_CONFIG="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
if ! grep -qsE "desktop-notifications[[:space:]]*=[[:space:]]*false" "$GHOSTTY_CONFIG"; then
  printf '\nGhostty config — add to %s:\n\n' "$GHOSTTY_CONFIG"
  printf '    desktop-notifications = false\n'
  printf '    bell-features = no-title\n\n'
fi

# ── summary ───────────────────────────────────────────────────────────────────

printf '\n'
if [ "$changes" -eq 0 ]; then
  printf 'Already up-to-date.\n'
else
  printf '%d update(s) applied.\n' "$changes"
fi
