// Running commands: quietly for answers (git, zellij), or with their output shown in the watcher's pane
// (the update steps).
import { spawn } from "node:child_process";

// Runs a command and resolves with its stdout. Rejects with stderr's last line when it fails.
export const capture = (cmd, args, { cwd, env } = {}) =>
  new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd, env: env ?? process.env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.stdout.on("data", (c) => (out += c));
    child.stderr.on("data", (c) => (err += c));
    child.on("error", (error) => reject(new Error(`${cmd}: ${error.message}`)));
    child.on("close", (code) => {
      if (code === 0) resolve(out);
      else reject(new Error(lastLine(err) || lastLine(out) || `${cmd} ${args.join(" ")} exited with ${code}`));
    });
  });

// Runs a command with its output passed through to ours (prefixed), keeping the last lines for the error.
export const stream = (cmd, args, { cwd, prefix = "", write = (s) => process.stdout.write(s) } = {}) =>
  new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let tail = "";
    const pass = (chunk) => {
      const text = String(chunk);
      tail = (tail + text).slice(-2000);
      write(prefix ? text.replace(/^(?=.)/gm, prefix) : text);
    };
    child.stdout.on("data", pass);
    child.stderr.on("data", pass);
    child.on("error", (error) => reject(new Error(`${cmd}: ${error.message}`)));
    child.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(lastLine(tail) || `${cmd} exited with ${code}`));
    });
  });

export const lastLine = (text) =>
  text
    .split("\n")
    .map((l) => l.replace(/\x1b\[[0-9;]*m/g, "").trim())
    .filter(Boolean)
    .pop() ?? "";
