#!/bin/bash
input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
"$(dirname "$0")/tab-title.sh" working "$session_id" > /dev/null
