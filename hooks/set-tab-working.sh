#!/bin/bash
input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
short_id=$(echo "$session_id" | cut -c1-8)
printf '\033]2;⏳ Claude Code [%s]\007' "$short_id" > /dev/tty 2>/dev/null
