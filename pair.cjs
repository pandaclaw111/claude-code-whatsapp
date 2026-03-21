#!/usr/bin/env node
/**
 * WhatsApp pairing utility — generates QR code for linking a device.
 *
 * Usage:
 *   WHATSAPP_STATE_DIR=~/.claude/channels/whatsapp node pair.cjs
 *
 * After scanning, keep the process running for at least 30 seconds
 * to allow the registration to complete.
 */

const {
  makeWASocket,
  useMultiFileAuthState,
  fetchLatestBaileysVersion,
  makeCacheableSignalKeyStore,
  DisconnectReason,
} = require("@whiskeysockets/baileys");
const pino = require("pino");
const qrcode = require("qrcode-terminal");
const fs = require("fs");

const AUTH_DIR = (process.env.WHATSAPP_STATE_DIR || "./state") + "/auth";
const logger = pino({ level: "silent" });

fs.mkdirSync(AUTH_DIR, { recursive: true });

async function start() {
  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
  const { version } = await fetchLatestBaileysVersion();

  console.log("Baileys version:", version);
  console.log("Auth dir:", AUTH_DIR);
  console.log("Waiting for QR code...\n");

  const sock = makeWASocket({
    auth: {
      creds: state.creds,
      keys: makeCacheableSignalKeyStore(state.keys, logger),
    },
    version,
    logger,
    browser: ["claude-code", "whatsapp", "1.0.0"],
    syncFullHistory: false,
    markOnlineOnConnect: false,
  });

  sock.ev.on("creds.update", saveCreds);

  sock.ev.on("connection.update", (u) => {
    if (u.qr) {
      qrcode.generate(u.qr, { small: true }, (code) => {
        console.log(code);
        console.log("^^^ Scan this QR code with WhatsApp > Linked Devices > Link a Device ^^^\n");
      });
    }
    if (u.connection === "open") {
      console.log("Connected! You can now send a test message.");
      console.log("Keep this process running for at least 30 seconds to complete registration.\n");
    }
    if (u.connection === "close") {
      const code = u.lastDisconnect?.error?.output?.statusCode;
      console.log("Connection closed:", code);
      if (code === 440) {
        console.log("Session conflict (440) — another process is using this session.");
        console.log("Make sure no other WhatsApp process is running.");
        return;
      }
      if (code === DisconnectReason.loggedOut) {
        console.log("Logged out. Delete auth/ directory and scan QR again.");
        process.exit(1);
      }
      console.log("Reconnecting in 3s...");
      setTimeout(start, 3000);
    }
  });

  sock.ev.on("messages.upsert", (m) => {
    for (const msg of m.messages || []) {
      if (msg.key.fromMe) continue;
      const text =
        msg.message?.conversation ||
        msg.message?.extendedTextMessage?.text ||
        "(media)";
      console.log(`Message received: "${text}" from ${msg.key.remoteJid}`);
    }
  });
}

start().catch((e) => {
  console.error("Fatal:", e);
  process.exit(1);
});

// Keep alive for 10 minutes
setTimeout(() => {
  console.log("Timeout — exiting.");
  process.exit(0);
}, 600000);
