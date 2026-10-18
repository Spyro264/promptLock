#!/bin/bash
LOG="$HOME/.claude/touchid-hook.log"
LIMIT=60
mkdir -p "$HOME/.claude"
echo "$(date '+%H:%M:%S') hook started" >> "$LOG"
cat > /dev/null

/usr/local/libexec/claude-touchid/touchid-check "send a Claude Code prompt" &
pid=$!
( sleep $LIMIT; kill $pid ) > /dev/null 2>&1 &
watcher=$!

wait $pid 2>/dev/null
code=$?
kill $watcher > /dev/null 2>&1

echo "$(date '+%H:%M:%S') touchid exit code: $code" >> "$LOG"
if [ $code -ne 0 ]; then
  if [ $code -gt 128 ]; then
    echo "Blocked: no fingerprint within $LIMIT seconds" >&2
  else
    echo "Blocked: fingerprint not verified" >&2
  fi
  exit 2
fi
exit 0
