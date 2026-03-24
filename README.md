# WhatsApp Channel for Claude Code

A custom [Claude Code Channels](https://docs.anthropic.com/en/docs/claude-code/channels) plugin that adds WhatsApp as a messaging channel, using [Baileys](https://github.com/WhiskeySockets/Baileys) v7 (WhatsApp Web Multi-Device protocol).

> **Note:** This is a personal project that I've open-sourced for the community. It works for my 24/7 setup and I'm sharing it as-is. PRs are welcome.

## How it works

```
WhatsApp (phone)
    ↕ Baileys v7.0.0-rc.9 (Multi-Device protocol)
server.cjs (MCP server with channel + permission relay capabilities)
    ↕ notifications/claude/channel
Claude Code (receives and responds to WhatsApp messages)
```

The plugin runs as an MCP server that connects to WhatsApp via Baileys, receives incoming messages, and pushes them to Claude Code as channel notifications. Claude can reply using the `reply` tool.

## Features (v0.0.3)

- **Production-grade stability** — connection patterns based on [OpenClaw](https://github.com/openclaw/openclaw)'s proven WhatsApp gateway
- **515 is normal** — WhatsApp restart requests are handled gracefully (reconnect in 2s, not crash)
- **Never crashes the process** — only stops on 440 (conflict) or 401 (logout); everything else reconnects
- **Exponential backoff with jitter** — factor 1.8, jitter 25%, max 30s, reset after healthy period
- **Watchdog** — detects stale connections (30min timeout) and forces reconnect
- **Credential backup** — auto-backup before each save, auto-restore if corrupted
- **Permission relay** — approve Claude Code tool use from your phone ("yes xxxxx" / "no xxxxx")
- **getMessage handler** — required for E2EE retry in Baileys v7
- **Crypto error recovery** — Baileys crypto errors trigger reconnect instead of crash
- **Graceful shutdown** — clean exit on SIGTERM/SIGINT/stdin close

## Requirements

- **Node.js** 20+ (Bun is NOT supported — lacks WebSocket events Baileys needs)
- **Claude Code** 2.1.80+ (with Channels support)
- **WhatsApp** account (regular or Business)

## Quick Start

### 1. Clone and install

```bash
git clone https://github.com/diogo85/claude-code-whatsapp.git
cd claude-code-whatsapp
npm install
```

### 2. Configure MCP server

Add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "whatsapp": {
      "command": "node",
      "args": ["/path/to/claude-code-whatsapp/server.cjs"],
      "env": {
        "WHATSAPP_STATE_DIR": "~/.claude/channels/whatsapp"
      }
    }
  }
}
```

### 3. Pair with WhatsApp

```bash
mkdir -p ~/.claude/channels/whatsapp/auth
WHATSAPP_STATE_DIR=~/.claude/channels/whatsapp node pair.cjs
```

The script shows both a **QR code** and a **pairing code**. On your phone:
- **QR:** WhatsApp > Linked Devices > Link a Device — scan the QR
- **Code:** WhatsApp > Linked Devices > Link a Device > Link with phone number — enter the code

Wait for "✅ WhatsApp connected!" before closing.

### 4. Start Claude Code

```bash
WHATSAPP_STATE_DIR=~/.claude/channels/whatsapp \
  claude --dangerously-load-development-channels "server:whatsapp"
```

On the first run, select "I am using this for local development" when prompted.

### 5. Access control (optional)

Create `~/.claude/channels/whatsapp/access.json`:

```json
{
  "allowFrom": ["5511999999999"],
  "allowGroups": false,
  "allowedGroups": [],
  "requireAllowFromInGroups": false
}
```

- `allowFrom: []` (empty) = accept messages from anyone
- `allowFrom: ["5511999999999"]` = only from this number
- `allowGroups: true` + `allowedGroups: ["xxx@g.us"]` = specific groups

## Tools

| Tool | Description |
|------|-------------|
| `reply` | Send text + file attachments (images, audio, video, documents) |
| `react` | Add an emoji reaction to a message |
| `download_attachment` | Download media from a received message |
| `fetch_messages` | List recent messages from session cache |

## Permission Relay

When Claude Code needs permission to run a tool, it can send the request to your WhatsApp:

```
🔐 Permission request [tbxkq]

Bash: rm -rf /tmp/foo

Reply "yes tbxkq" or "no tbxkq"
```

Reply from your phone and Claude Code will proceed (or stop). The plugin reacts with ✅ or ❌ to confirm.

Requires Claude Code v2.1.81+ and the `claude/channel/permission` capability (enabled by default in v0.0.3).

## Stability Design

This plugin was rewritten based on analysis of [OpenClaw's WhatsApp extension](https://github.com/openclaw/openclaw/tree/main/extensions/whatsapp), which runs 24/7 without issues. Key patterns:

| Pattern | Description |
|---------|-------------|
| 515 = reconnect | WhatsApp sends 515 regularly. It's a normal restart request, not an error |
| Never process.exit | Only stop on 440 (conflict) or 401 (logout). Everything else reconnects |
| New socket each time | Never reuse a dead socket — create fresh on every reconnect |
| Backoff with jitter | Prevents thundering herd. Reset after 60s of healthy connection |
| Watchdog timer | 30min without inbound messages = force reconnect (detects zombie connections) |
| Creds backup | Auto-backup before each save. Auto-restore if JSON is corrupted |
| Listener cleanup | Remove all event listeners before creating new socket (prevents leaks) |

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| "WhatsApp not connected" | Auth expired or not paired | Run `pair.cjs` and scan QR |
| Error 515 | Normal — WhatsApp requested restart | v0.0.3 handles automatically. If old version: update |
| Error 440 | Two devices competing | Unlink in phone settings, re-pair |
| Error 401 | Logged out | Session invalidated, re-pair |
| Rate limit on pairing | Too many rapid attempts | Wait 1-2 hours, try ONCE |
| Messages stop without error | Zombie connection | Watchdog (v0.0.3) detects in 30min. Or restart manually |
| creds.json corrupted | Crash during save | v0.0.3 restores from backup automatically |

## Changelog

### v0.0.3 (2026-03-24)
- **Breaking:** Rewrote connection lifecycle based on OpenClaw patterns
- 515 treated as normal reconnect (was fatal `process.exit`)
- Never `process.exit` in reconnect loop (only 440/401 stop)
- Exponential backoff with jitter + reset after healthy period (60s)
- Watchdog detects stale connections (30min timeout)
- Credential backup/restore before each save
- `getMessage` handler for E2EE retry (required in Baileys v7)
- Crypto error handler (reconnect instead of crash)
- Permission relay capability (`claude/channel/permission`)
- `process.setMaxListeners(50)` to avoid warnings
- Full listener cleanup before reconnecting

### v0.0.2 (2026-03-23)
- `browser` fixed to `["Mac OS", "Safari", "1.0.0"]` (valid for Baileys v7)
- Basic exponential backoff + max retries
- Creds save with retry
- Permission relay (outbound + inbound)

### v0.0.1 (2026-03-21)
- Initial implementation based on OpenClaw's architecture
- Baileys v7.0.0-rc.9
- MCP server with channel capability
- 4 tools: reply, react, download_attachment, fetch_messages
- Access control via allowlist
- Deduplication cache (20min TTL)

## License

MIT
