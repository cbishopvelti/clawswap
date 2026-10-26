#!/usr/bin/env node
// clawswap: runs a project's dev servers in a zellij session and switches its checkout to another branch
// from a Stream Deck key, a browser page or the command line. See README.md.
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const cli = resolve(dirname(fileURLToPath(import.meta.url)), "../lib/cli.mjs");
const args = process.argv.slice(2);
// The watcher exits with 75 after a switch that changed its config, so the new one takes over.
for (;;) {
  const { status, signal } = spawnSync(process.execPath, [cli, ...args], { stdio: "inherit" });
  if (args[0] === "watch" && status === 75) continue;
  process.exit(status ?? (signal ? 1 : 0));
}
