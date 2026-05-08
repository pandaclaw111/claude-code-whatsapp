#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export TMUX_TMPDIR=/tmp

LOG="$HOME/claude-code-whatsapp/logs/watchdog.log"
mkdir -p "$HOME/claude-code-whatsapp/logs"
TS="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Pairing lock: if this file exists, skip all restarts (pairing in progress).
PAIRING_LOCK="$HOME/.local/share/whatsapp-channel/pairing.in_progress"
if [ -f "$PAIRING_LOCK" ]; then
  echo "$TS Pairing lock active — skipping watchdog checks" >> "$LOG"
  exit 0
fi

restart_whatsapp() {
  pkill -9 -f "claude-code-whatsapp/server.cjs" 2>/dev/null
  tmux kill-session -t whatsapp 2>/dev/null
  sleep 2
  CLAUDE_BIN="/Users/pandaclaw/.nvm/versions/node/v22.22.1/bin/claude"
  tmux new-session -d -s whatsapp "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING -u AI_AGENT WHATSAPP_STATE_DIR=$HOME/.local/share/whatsapp-channel bash -c 'source ~/.nvm/nvm.sh && cd ~ && $CLAUDE_BIN --model claude-sonnet-4-6 --dangerously-load-development-channels server:whatsapp --dangerously-skip-permissions'"
  # Smart key-sending: check pane content and respond to the correct dialog.
  # Avoids race with keep-alive.sh which may also be sending keys.
  for i in 1 2 3 4 5; do
    sleep 4
    PANE=$(tmux capture-pane -t whatsapp -p 2>/dev/null)
    if echo "$PANE" | grep -q "No, exit"; then
      tmux send-keys -t whatsapp Down Enter  # accept bypass permissions
    elif echo "$PANE" | grep -q "local development"; then
      tmux send-keys -t whatsapp Enter       # accept channel warning
      break
    elif echo "$PANE" | grep -q "Listening for channel\|bypass permissions on"; then
      break  # already running
    fi
  done
}

# LAYER 1 — Process liveness
if ! tmux has-session -t whatsapp 2>/dev/null; then
  echo "$TS L1: Session dead. Restarting..." >> "$LOG"
  restart_whatsapp
  echo "$TS L1: Restarted." >> "$LOG"
  exit 0
fi

BRIDGE_COUNT=$(pgrep -f "claude-code-whatsapp/server.cjs" 2>/dev/null | wc -l | tr -d ' ')
if [ "$BRIDGE_COUNT" -gt 1 ]; then
  echo "$TS L1: $BRIDGE_COUNT bridges. Killing dupes..." >> "$LOG"
  NEWEST=$(pgrep -f "claude-code-whatsapp/server.cjs" | tail -1)
  for pid in $(pgrep -f "claude-code-whatsapp/server.cjs"); do
    [ "$pid" != "$NEWEST" ] && kill -9 "$pid" 2>/dev/null
  done
  echo "$TS L1: Dupes killed." >> "$LOG"
fi

if [ "$BRIDGE_COUNT" -eq 0 ]; then
  echo "$TS L1: Bridge dead. Restarting..." >> "$LOG"
  restart_whatsapp
  echo "$TS L1: Restarted." >> "$LOG"
  exit 0
fi

# LAYER 2 — Hang detection
PANE=$(tmux capture-pane -t whatsapp -p 2>&1)

if echo "$PANE" | grep -qE "Do you want|Enter to confirm|Yes.*No|accept.*exit"; then
  echo "$TS L2: Stuck on prompt. Approving..." >> "$LOG"
  tmux send-keys -t whatsapp Down Enter
  sleep 2
  exit 0
fi

IDLE_FILE="$HOME/claude-code-whatsapp/logs/.idle_count"
if echo "$PANE" | grep -qE "Process completed|Saving session|pandaclaw.*%"; then
  echo "$TS L2: Session ended. Restarting..." >> "$LOG"
  restart_whatsapp
  echo "$TS L2: Restarted." >> "$LOG"
  echo "0" > "$IDLE_FILE"
  exit 0
fi

# LAYER 3 — Stuck thinking detection
# If Claude has been Spinning/Thinking/Wibbling for too long, it can't process
# new messages. Track consecutive "busy" ticks and interrupt after 5 min.
BUSY_FILE="$HOME/claude-code-whatsapp/logs/.busy_count"
if echo "$PANE" | grep -qE "Spinning|Wibbling|Ruminating|Crunching|thinking"; then
  BUSY=$(cat "$BUSY_FILE" 2>/dev/null || echo 0)
  BUSY=$((BUSY + 1))
  echo "$BUSY" > "$BUSY_FILE"
  if [ "$BUSY" -ge 5 ]; then
    echo "$TS L3: Claude stuck thinking for ${BUSY}+ min. Interrupting..." >> "$LOG"
    tmux send-keys -t whatsapp Escape
    sleep 2
    echo "0" > "$BUSY_FILE"
    exit 0
  fi
  echo "$TS L3: Claude busy (${BUSY}/5 ticks)" >> "$LOG"
  exit 0
fi
echo "0" > "$BUSY_FILE" 2>/dev/null

echo "$TS OK" >> "$LOG"
echo "0" > "$IDLE_FILE" 2>/dev/null
