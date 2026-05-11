#!/bin/bash
# PreCompact hook for PandaClaw (WhatsApp channel).
#
# Fires just before Claude Code runs /compact. The hook receives the conversation
# transcript on stdin (Claude Code hooks contract). We extract the most recent
# activity and write a lightweight "in-flight" snapshot to the project auto-memory
# directory, so that even after the in-context summary is compacted further or
# the agent restarts, key recent state survives.
#
# Hook contract:
#   stdin  → JSON event payload (varies by Claude Code version)
#   stdout → ignored (logged for debugging)
#   exit 0 → allow compaction to proceed (we never block)

set -u
# Compute Claude Code's per-project memory dir from current PWD.
# Encoding: replace "/" with "-" (e.g., /Users/alice -> -Users-alice)
PROJECT_ID="$(pwd | sed 's,/,-,g')"
MEMORY_DIR="$HOME/.claude/projects/${PROJECT_ID}/memory"
SNAPSHOT="$MEMORY_DIR/project_in_flight.md"
INDEX="$MEMORY_DIR/MEMORY.md"
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

mkdir -p "$MEMORY_DIR" 2>/dev/null
# Bootstrap MEMORY.md index if missing (first-run safety)
[ -f "$INDEX" ] || : > "$INDEX"

# Best-effort: read recent bridge activity so the post-compact agent knows what
# WhatsApp messages were in motion. Capped to avoid bloat.
BRIDGE_LOG="${WHATSAPP_STATE_DIR:-$HOME/.local/share/whatsapp-channel}/bridge.log"
RECENT_BRIDGE=""
if [ -f "$BRIDGE_LOG" ]; then
  RECENT_BRIDGE=$(tail -40 "$BRIDGE_LOG" 2>/dev/null | grep -E "reply -> |upsert: [0-9]+ msgs|connected as|disconnect" | tail -10)
fi

cat > "$SNAPSHOT" <<EOF
---
name: In-flight snapshot
description: Pre-compact snapshot of recent WhatsApp bridge activity. Helps post-compact agent re-orient.
type: project
---

Last pre-compact snapshot: $TS

**Why:** /compact replaces in-context detail with a summary. This file captures the most recent bridge activity so the post-compact agent can re-orient without losing the thread of recent WhatsApp work.

**How to apply:** Read on session start. If a user references something recent that the summary doesn't cover, cross-check this snapshot and call \`fetch_messages\` against the chat_id mentioned here.

**Recent bridge activity (last 10 events):**
\`\`\`
${RECENT_BRIDGE:-(no recent bridge activity logged)}
\`\`\`

**Note:** This file is overwritten on every /compact. For durable knowledge, use the regular memory MDs in this directory.
EOF

# Add MEMORY.md index entry if not already there
if ! grep -q "project_in_flight" "$INDEX" 2>/dev/null; then
  echo "- [In-flight snapshot](project_in_flight.md) — pre-compact snapshot of recent bridge activity (auto-overwritten)" >> "$INDEX"
fi

exit 0
