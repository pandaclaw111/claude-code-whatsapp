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
  CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.nvm/versions/node/$(node --version 2>/dev/null | tr -d v)/bin/claude")}"
  WHATSAPP_STATE="${WHATSAPP_STATE_DIR:-$HOME/.local/share/whatsapp-channel}"
  tmux new-session -d -s whatsapp "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING -u AI_AGENT WHATSAPP_STATE_DIR=$WHATSAPP_STATE bash -c 'source ~/.nvm/nvm.sh && cd ~ && $CLAUDE_BIN --model claude-sonnet-4-6 --dangerously-load-development-channels server:whatsapp --dangerously-skip-permissions'"
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
  # Dialog-specific responses. Channel warning ("local development") needs just Enter;
  # bypass-permissions dialog ("No, exit") needs Down+Enter to select Yes.
  if echo "$PANE" | grep -q "local development"; then
    echo "$TS L2: Channel warning dialog. Sending Enter..." >> "$LOG"
    tmux send-keys -t whatsapp Enter
  elif echo "$PANE" | grep -q "No, exit"; then
    echo "$TS L2: Bypass-perms dialog. Sending Down+Enter..." >> "$LOG"
    tmux send-keys -t whatsapp Down Enter
  else
    echo "$TS L2: Unknown confirm dialog. Sending Enter (safe default)..." >> "$LOG"
    tmux send-keys -t whatsapp Enter
  fi
  sleep 2
  exit 0
fi

IDLE_FILE="$HOME/claude-code-whatsapp/logs/.idle_count"
if echo "$PANE" | grep -qE "Process completed|Saving session|[a-z].*%$"; then
  echo "$TS L2: Session ended. Restarting..." >> "$LOG"
  restart_whatsapp
  echo "$TS L2: Restarted." >> "$LOG"
  echo "0" > "$IDLE_FILE"
  exit 0
fi

# LAYER 3 — Stuck thinking detection
# Canonical busy signal: "esc to interrupt" appears in the footer ONLY when Claude is actively
# running. Avoids whack-a-mole verb matching (Crunching, Cooking, Drizzling, Fiddle-faddling, …)
# which false-positives on the same words appearing in reply text in scrollback.
# After 15 min of continuous busy: send Escape. After 25 min: kill+restart.
# Critically, falls through to L4a/L4b — busy state alone doesn't prove healthy.
BUSY_FILE="$HOME/claude-code-whatsapp/logs/.busy_count"
if echo "$PANE" | grep -q "esc to interrupt"; then
  BUSY=$(cat "$BUSY_FILE" 2>/dev/null || echo 0)
  BUSY=$((BUSY + 1))
  echo "$BUSY" > "$BUSY_FILE"
  if [ "$BUSY" -ge 25 ]; then
    echo "$TS L3: Claude busy ${BUSY}+ min after escape. Kill+restart." >> "$LOG"
    echo "0" > "$BUSY_FILE"
    restart_whatsapp
    echo "$TS L3: Restarted." >> "$LOG"
    exit 0
  elif [ "$BUSY" -eq 15 ]; then
    echo "$TS L3: Claude busy 15min. Sending Escape..." >> "$LOG"
    tmux send-keys -t whatsapp Escape
    exit 0
  else
    echo "$TS L3: Claude busy (${BUSY}/15 ticks)" >> "$LOG"
    # Fall through — reply-gap check is more authoritative
  fi
else
  echo "0" > "$BUSY_FILE" 2>/dev/null
fi

# LAYER 3b — Stuck queued input (idle but message in input box not submitted)
# Failure mode: channel injects msg into input box but never sends Enter.
# Detection: pane idle (no "esc to interrupt"), and input box line "❯ X" has non-placeholder content.
# Submit by sending Enter. Placeholder is "❯ Try \"...\"" or empty after ❯ .
QUEUED_FILE="$HOME/claude-code-whatsapp/logs/.queued_count"
if ! echo "$PANE" | grep -q "esc to interrupt"; then
  # Extract the LAST "❯<separator><content>" line. Claude Code uses a non-breaking space
  # (U+00A0, bytes \xc2\xa0) after the ❯ glyph, NOT a regular space — so we match ^❯ (no space)
  # and strip the ❯ + any whitespace bytes including NBSP.
  INPUT_LINE=$(echo "$PANE" | grep '^❯' | tail -1 | sed $'s/^❯[\xc2\xa0[:space:]]*//')
  # skip if empty, or starts with Try "..." (placeholder), or starts with /help-like single-token suggestion
  if [ -n "$INPUT_LINE" ] && ! echo "$INPUT_LINE" | grep -qE '^Try "'; then
    QC=$(cat "$QUEUED_FILE" 2>/dev/null || echo 0)
    QC=$((QC + 1))
    echo "$QC" > "$QUEUED_FILE"
    if [ "$QC" -ge 2 ]; then
      # confirmed stuck across 2 ticks — submit
      echo "$TS L3b: Queued input stuck (\"$(echo "$INPUT_LINE" | cut -c1-40)\"). Sending Enter..." >> "$LOG"
      tmux send-keys -t whatsapp Enter
      echo "0" > "$QUEUED_FILE"
      sleep 2
      exit 0
    fi
    echo "$TS L3b: queued input tick ${QC}/2" >> "$LOG"
  else
    echo "0" > "$QUEUED_FILE" 2>/dev/null
  fi
fi

# LAYER 4a — Context-limit / compaction stuck detection
# When Claude hits context limit it shows "Context limit reached · /compact or /clear".
# When it compacts: "Compacting conversation…". These are non-busy states that block message processing.
# Grace period: allow 4 min for /compact to legitimately run on large contexts; intervene after that.
COMPACT_FILE="$HOME/claude-code-whatsapp/logs/.compact_count"
if echo "$PANE" | grep -qE "Context limit reached|Compacting conversation"; then
  CTX=$(cat "$COMPACT_FILE" 2>/dev/null || echo 0)
  CTX=$((CTX + 1))
  echo "$CTX" > "$COMPACT_FILE"
  if echo "$PANE" | grep -q "Context limit reached" && ! echo "$PANE" | grep -q "Compacting conversation"; then
    # Limit hit but compact not started — kick it off
    echo "$TS L4a: Context limit reached, sending /compact (${CTX}/4 ticks)" >> "$LOG"
    tmux send-keys -t whatsapp Escape
    sleep 1
    tmux send-keys -t whatsapp "/compact" Enter
    exit 0
  fi
  if [ "$CTX" -ge 4 ]; then
    # Compaction running >4min — likely stuck. Kill+restart (memory MDs + bridge history persist)
    echo "$TS L4a: Compaction stuck for ${CTX}+ min. Restarting (memory persists)..." >> "$LOG"
    echo "0" > "$COMPACT_FILE"
    restart_whatsapp
    echo "$TS L4a: Restarted." >> "$LOG"
    exit 0
  fi
  echo "$TS L4a: Compacting (${CTX}/4 ticks)" >> "$LOG"
  exit 0
fi
echo "0" > "$COMPACT_FILE" 2>/dev/null

# LAYER 4b — Reply-gap detection (end-to-end health check)
# If the bridge logs many ACTIONABLE incoming msgs but no replies for 10+ min, Claude is silently dead.
# "Actionable" = upsert NOT immediately followed by a skip line (group/echo/system).
# Post-restart cooldown: skip this check if bridge reconnected within last 5 min.
BRIDGE_LOG="${WHATSAPP_STATE_DIR:-$HOME/.local/share/whatsapp-channel}/bridge.log"
GAP_FILE="$HOME/claude-code-whatsapp/logs/.gap_count"
if [ -f "$BRIDGE_LOG" ]; then
  COOLDOWN=$(date -u -v-5M '+%Y-%m-%dT%H:%M' 2>/dev/null || date -u -d '5 min ago' '+%Y-%m-%dT%H:%M')
  RECENT_CONNECT=$(awk -v cut="$COOLDOWN" '$1 >= cut && /connected as /' "$BRIDGE_LOG" 2>/dev/null | head -1)
  if [ -n "$RECENT_CONNECT" ]; then
    # Bridge reconnected recently — give it grace
    echo "$TS L4b: skip — bridge reconnected in last 5min" >> "$LOG"
    echo "0" > "$GAP_FILE" 2>/dev/null
  else
    CUTOFF=$(date -u -v-10M '+%Y-%m-%dT%H:%M' 2>/dev/null || date -u -d '10 min ago' '+%Y-%m-%dT%H:%M')
    RECENT=$(awk -v cut="$CUTOFF" '$1 >= cut' "$BRIDGE_LOG" 2>/dev/null)
    # Actionable upserts = total upserts minus all "skip" outcomes (group, echo, system, non-self)
    UPSERTS_TOTAL=$(echo "$RECENT" | grep -c "upsert: [0-9]\+ msgs" 2>/dev/null || echo 0)
    SKIPS=$(echo "$RECENT" | grep -cE "upsert skip|skip system message" 2>/dev/null || echo 0)
    ACTIONABLE=$((UPSERTS_TOTAL - SKIPS))
    REPLIES=$(echo "$RECENT" | grep -c "reply -> " 2>/dev/null || echo 0)
    # Only act if there are clearly unanswered direct/relevant messages
    if [ "$ACTIONABLE" -ge 3 ] && [ "$REPLIES" -eq 0 ]; then
      GAP=$(cat "$GAP_FILE" 2>/dev/null || echo 0)
      GAP=$((GAP + 1))
      echo "$GAP" > "$GAP_FILE"
      if [ "$GAP" -ge 3 ]; then
        echo "$TS L4b: ${ACTIONABLE} actionable msgs / 0 replies in 10min for ${GAP}+ ticks. Restarting..." >> "$LOG"
        echo "0" > "$GAP_FILE"
        restart_whatsapp
        echo "$TS L4b: Restarted." >> "$LOG"
        exit 0
      fi
      echo "$TS L4b: Reply gap (${ACTIONABLE} actionable in / 0 out) tick ${GAP}/3" >> "$LOG"
      exit 0
    fi
    echo "0" > "$GAP_FILE" 2>/dev/null
  fi
fi

echo "$TS OK" >> "$LOG"
echo "0" > "$IDLE_FILE" 2>/dev/null
