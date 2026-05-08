#!/usr/bin/env node
// Standalone WhatsApp pairing — run from plugin dir for node_modules
// Usage: cd ~/.claude/plugins/cache/nexus-plugins/whatsapp/0.0.1 && node ~/nexus/scripts/whatsapp-pair.cjs
const { default: makeWASocket, useMultiFileAuthState, makeCacheableSignalKeyStore, fetchLatestBaileysVersion, DisconnectReason } = require("@whiskeysockets/baileys");
const qrcode = require("qrcode-terminal");
const pino = require("pino");

const AUTH_DIR = process.env.WHATSAPP_STATE_DIR
  ? require("path").join(process.env.WHATSAPP_STATE_DIR, "auth")
  : require("path").join(require("os").homedir(), ".claude/channels/whatsapp/auth");

console.log("WhatsApp pairing — auth dir:", AUTH_DIR);
console.log("Connecting...\n");

(async () => {
  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
  const { version } = await fetchLatestBaileysVersion();
  const logger = pino({ level: "silent" });

  const sock = makeWASocket({
    auth: { creds: state.creds, keys: makeCacheableSignalKeyStore(state.keys, logger) },
    version,
    logger,
    browser: ["Mac OS", "Safari", "1.0.0"],
    syncFullHistory: false,
    markOnlineOnConnect: false,
  });

  sock.ev.on("creds.update", saveCreds);

  // Request pairing code (phone-based, no QR scan needed)
  if (!state.creds.registered) {
    setTimeout(async () => {
      try {
        const phone = process.env.WHATSAPP_PHONE;
        if (!phone) throw new Error("Set WHATSAPP_PHONE env var to your number (e.g. 12125551234)");
        const code = await sock.requestPairingCode(phone);
        console.log(`\n📱 PAIRING CODE: ${code}\n`);
        console.log("WhatsApp > Linked Devices > Link a Device > Link with phone number");
        console.log("Enter the code above.\n");
      } catch (e) {
        console.error("Pairing code failed, waiting for QR instead...");
      }
    }, 3000);
  }

  sock.ev.on("connection.update", (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      qrcode.generate(qr, { small: true }, (code) => {
        console.log("\n📱 Or scan this QR:\n");
        console.log(code);
      });
    }

    if (connection === "open") {
      console.log("\n✅ WhatsApp connected! Auth saved. Closing in 3s...");
      setTimeout(() => process.exit(0), 3000);
    }

    if (connection === "close") {
      const reason = lastDisconnect?.error?.output?.statusCode;
      if (reason === DisconnectReason.loggedOut || reason === 440 || reason === 515) {
        console.log(`❌ Error ${reason}. Delete auth/ and try again after a few minutes.`);
        process.exit(1);
      }
      console.log(`Connection closed (${reason}), retrying...`);
      setTimeout(() => process.exit(1), 1000);
    }
  });
})();
