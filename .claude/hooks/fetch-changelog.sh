#!/bin/bash
# SessionStart hook: fetch and cache the Claude Code changelog.
#
# Downloads https://code.claude.com/docs/en/changelog, converts HTML to plain
# text via textutil (macOS built-in), and saves to ~/.claude/.ccg/changelog.md.
# Skips the fetch if the cached file is less than 12 hours old.
#
# The cached file is read by Claude at session start (see CLAUDE.md rule) so
# that new features and breaking changes are always in context before work begins.

CACHE="${CCG_DIR:-$HOME/.claude/.ccg}/changelog.md"
CACHE_MAX_AGE=43200  # 12 hours

if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(date -r "$CACHE" +%s 2>/dev/null || echo 0) ))
  [ "$age" -lt "$CACHE_MAX_AGE" ] && exit 0
fi

mkdir -p "$(dirname "$CACHE")"

tmp=$(mktemp)
if curl -sf --max-time 15 "https://code.claude.com/docs/en/changelog" -o "$tmp"; then
  textutil -format html -convert txt -stdin -stdout < "$tmp" \
    > "${CACHE}.tmp" 2>/dev/null \
    && mv "${CACHE}.tmp" "$CACHE"
fi
rm -f "$tmp" "${CACHE}.tmp"

exit 0
