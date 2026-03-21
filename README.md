# WhatsApp Channel for Claude Code

A custom [Claude Code Channels](https://docs.anthropic.com/en/docs/claude-code/channels) plugin that adds WhatsApp as a messaging channel, using [Baileys](https://github.com/WhiskeySockets/Baileys) (WhatsApp Web Multi-Device protocol).

> **Note:** This is a personal project that I've open-sourced for the community. It works for my setup and I'm sharing it as-is. No support or maintenance is guaranteed — feel free to fork and adapt to your needs. PRs are welcome.

## How it works

```
WhatsApp (phone)
    ↕ Baileys v7 (Multi-Device protocol)
server.cjs (MCP server with channel capability)
    ↕ notifications/claude/channel
Claude Code (receives and responds to WhatsApp messages)
```

The plugin runs as an MCP server that connects to WhatsApp via Baileys, receives incoming messages, and pushes them to Claude Code as channel notifications. Claude can reply using the `reply` tool.

## Requirements

- **Node.js** 20+ (Bun is NOT supported — lacks WebSocket events Baileys needs)
- **Claude Code** 2.1.80+ (with Channels support)
- **WhatsApp** account (regular or Business)

## Setup

### 1. Install the plugin

```bash
# Add as a local marketplace
claude plugin marketplace add /path/to/claude-code-whatsapp

# Or from GitHub
claude plugin marketplace add github:diogo85/claude-code-whatsapp

# Install
claude plugin install whatsapp@claude-code-whatsapp
```

### 2. Configure the MCP server

Add to your project's `.mcp.json` (in the working directory where Claude Code runs):

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

### 3. Pair with WhatsApp (QR code)

```bash
# Create state directory
mkdir -p ~/.claude/channels/whatsapp/auth

# Install dependencies
cd /path/to/claude-code-whatsapp && npm install

# Generate QR code
WHATSAPP_STATE_DIR=~/.claude/channels/whatsapp node pair.cjs
```

On your phone: **WhatsApp > Settings > Linked Devices > Link a Device** — scan the QR code.

Keep the process running for at least 30 seconds after scanning to complete registration.

### 4. Start Claude Code with WhatsApp

```bash
WHATSAPP_STATE_DIR=~/.claude/channels/whatsapp \
  claude --channels "plugin:discord@claude-plugins-official" \
  --dangerously-load-development-channels "server:whatsapp" \
  --dangerously-skip-permissions
```

On the first run, Claude Code will ask you to confirm that you're using this for local development. Select option 1.

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
- `allowFrom: ["5511999999999"]` = only accept from this number

## Tools

The plugin exposes 4 tools to Claude:

| Tool | Description |
|------|-------------|
| `reply` | Send a text message (with optional file attachments) |
| `react` | Add an emoji reaction to a message |
| `download_attachment` | Download media from a received message |
| `fetch_messages` | List recent messages from session cache |

## Important notes

- **One process at a time:** Never run two WhatsApp processes simultaneously — this causes error 440 (session conflict) and an infinite reconnection loop.
- **Session expiry:** WhatsApp sessions expire after ~14 days of inactivity. Re-run `pair.cjs` to scan a new QR code.
- **Development channels:** Since this is not an official Claude Code plugin, you must use `--dangerously-load-development-channels "server:whatsapp"` every time you start Claude Code.
- **Baileys is unofficial:** [Baileys](https://github.com/WhiskeySockets/Baileys) reverse-engineers the WhatsApp Web protocol. WhatsApp may ban accounts using unofficial clients. Use at your own risk.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Error 440 in loop | Kill ALL node processes related to WhatsApp, wait 30s, restart |
| "not on approved channels allowlist" | Make sure you're using `--dangerously-load-development-channels "server:whatsapp"` |
| QR code not appearing | Delete `~/.claude/channels/whatsapp/auth/` and try again |
| Messages not received | Check that no other process is using the same WhatsApp session |
| "plugin not installed" | Run `claude plugin install whatsapp@claude-code-whatsapp` |

## License

MIT
