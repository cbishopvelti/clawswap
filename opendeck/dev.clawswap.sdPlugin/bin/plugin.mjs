// The clawswap plugin for OpenDeck (and the Elgato Stream Deck app). OpenDeck starts it as
//   node bin/plugin.mjs -port <port> -pluginUUID <uuid> -registerEvent <event> -info <json>
// and it talks to OpenDeck over that WebSocket; see branches.mjs for what the keys do.
import { createBranchKeys } from "./branches.mjs";

const arg = (name) => {
  const i = process.argv.indexOf(`-${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
};

const port = arg("port");
const uuid = arg("pluginUUID");
const registerEvent = arg("registerEvent");

if (typeof WebSocket === "undefined") {
  console.error("clawswap plugin: this Node.js has no WebSocket; it needs Node.js 22 or newer.");
  process.exit(1);
}

const socket = new WebSocket(`ws://127.0.0.1:${port}`);
const send = (message) => {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
};
const keys = createBranchKeys({ send, url: process.env.CLAWSWAP_URL || undefined, log: (text) => console.log(text) });

socket.addEventListener("open", () => socket.send(JSON.stringify({ event: registerEvent, uuid })));
socket.addEventListener("message", (event) => {
  try {
    keys.handle(JSON.parse(String(event.data)));
  } catch (error) {
    console.error("clawswap plugin:", error);
  }
});
socket.addEventListener("close", () => process.exit(0));
