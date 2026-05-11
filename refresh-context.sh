#!/bin/bash
# Scheduled context refresh — runs every 12h via launchd.
# Sends /compact to the tmux Claude session so context stays bounded
# and never grows to the point where automatic context-limit handling
# stalls the agent (the failure we hit on 2026-05-11).
#
# /compact is NON-destructive: it summarises old context, session continues.
# Combined with the PreCompact hook (writes in-flight snapshot to memory)
# and the auto-memory MDs, no durable knowledge is lost.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export TMUX_TMPDIR=/tmp

LOG="$HOME/claude-code-whatsapp/logs/refresh-context.log"
mkdir -p "$HOME/claude-code-whatsapp/logs"
TS="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Skip if no tmux session (let the watchdog start one first)
if ! tmux has-session -t whatsapp 2>/dev/null; then
  echo "$TS skip — no tmux session" >> "$LOG"
  exit 0
fi

# Skip if pairing is in progress
if [ -f "$HOME/.local/share/whatsapp-channel/pairing.in_progress" ]; then
  echo "$TS skip — pairing lock active" >> "$LOG"
  exit 0
fi

PANE=$(tmux capture-pane -t whatsapp -p 2>/dev/null)

# Skip if Claude is mid-reply (avoid interrupting work)
if echo "$PANE" | grep -qE "Spinning|Wibbling|Ruminating|Crunching|Cooking|Baking|Brewing|Pondering|Cogitating|Forging|Compacting|thinking"; then
  echo "$TS skip — Claude is busy" >> "$LOG"
  exit 0
fi

# Skip if already in compact-needed state — watchdog L4a will handle it
if echo "$PANE" | grep -q "Context limit reached"; then
  echo "$TS skip — context already at limit (watchdog will handle)" >> "$LOG"
  exit 0
fi

echo "$TS sending /compact for scheduled refresh" >> "$LOG"
tmux send-keys -t whatsapp Escape
sleep 1
tmux send-keys -t whatsapp "/compact" Enter
exit 0
