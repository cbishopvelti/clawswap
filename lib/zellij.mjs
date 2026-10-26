// The project's zellij session (zellij 0.44 or newer, for --pane-id): the layout `up` opens, and restarting
// the servers' panes in it.
import { readdir, readFile, readlink } from "node:fs/promises";
import { connect } from "node:net";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { capture } from "./run.mjs";

const tool = resolve(dirname(fileURLToPath(import.meta.url)), "..");
// Runs a pane's command and leaves a shell there when it stops. A single argument goes through sh -c.
export const KEEP = `${tool}/bin/keep`;
export const CLI = `${tool}/bin/clawswap.mjs`;

export const zellijVersion = async () => {
  const out = await capture("zellij", ["--version"]);
  return out.match(/(\d+)\.(\d+)\.(\d+)/)?.slice(1).map(Number);
};

export const versionOk = (v) => !!v && (v[0] > 0 || v[1] >= 44);

const kdlString = (s) => `"${String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
const keepArgs = (command) => [].concat(command);

// The layout `up` opens when the config names none: the servers stacked on the left, the watcher and the
// other panes on the right. The watcher finds the servers' panes by these names.
export const layout = (project) => {
  const pane = (name, { command, cwd }, focus) =>
    `pane name=${kdlString(name)} command=${kdlString(KEEP)} cwd=${kdlString(resolve(project.root, cwd ?? "."))}${focus ? " focus=true" : ""} {\n` +
    `    args ${keepArgs(command).map(kdlString).join(" ")}\n}`;
  const indent = (text, n) => text.replace(/^/gm, " ".repeat(n));
  const servers = Object.entries(project.servers).map(([name, s], i) => pane(name, s, i === 0));
  const side = [pane("clawswap", { command: [process.execPath, CLI, "watch"], cwd: "." }, !servers.length), ...Object.entries(project.panes).map(([name, p]) => pane(name, p))];
  const column = (panes, size) => `pane split_direction="horizontal"${size ? ` size="${size}"` : ""} {\n${indent(panes.join("\n"), 4)}\n}`;
  const body = servers.length ? `pane split_direction="vertical" {\n${indent(column(servers, "60%"), 4)}\n${indent(column(side), 4)}\n}` : column(side);
  return `// Written by clawswap for ${project.name}; set layout in ${project.file} to use your own.
layout {
    default_tab_template {
        pane size=1 borderless=true {
            plugin location="zellij:tab-bar"
        }
        children
        pane size=2 borderless=true {
            plugin location="zellij:status-bar"
        }
    }
    tab name=${kdlString(project.name)} focus=true {
${indent(body, 8)}
    }
}
`;
};

const portOpen = (port) =>
  new Promise((resolve) => {
    const socket = connect({ port, host: "127.0.0.1" });
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => resolve(false));
  });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export const waitForPort = async (port, ms = 30_000) => {
  for (let waited = 0; waited < ms && !(await portOpen(port)); waited += 500) await sleep(500);
};

// Whoever listens on the port. On Linux: the listening sockets' inodes from /proc/net/tcp*, then the
// processes holding them. Elsewhere: lsof. Only your own processes can be seen, which are the only ones we
// could stop.
export const portPids = async (port) => {
  if (process.platform !== "linux") {
    const out = await capture("lsof", ["-t", `-iTCP:${port}`, "-sTCP:LISTEN"]).catch(() => "");
    return out.split("\n").filter(Boolean).map(Number);
  }
  const hex = port.toString(16).toUpperCase().padStart(4, "0");
  const inodes = new Set();
  for (const file of ["/proc/net/tcp", "/proc/net/tcp6"]) {
    const text = await readFile(file, "utf8").catch(() => "");
    for (const line of text.split("\n").slice(1)) {
      const cols = line.trim().split(/\s+/);
      // local_address is ADDR:PORT; state 0A is LISTEN.
      if (cols[1]?.endsWith(`:${hex}`) && cols[3] === "0A") inodes.add(cols[9]);
    }
  }
  if (!inodes.size) return [];
  const pids = [];
  for (const pid of (await readdir("/proc")).filter((d) => /^\d+$/.test(d))) {
    const fds = await readdir(`/proc/${pid}/fd`).catch(() => []);
    for (const fd of fds) {
      const link = await readlink(`/proc/${pid}/fd/${fd}`).catch(() => "");
      if (inodes.has(link.match(/^socket:\[(\d+)\]$/)?.[1])) {
        pids.push(Number(pid));
        break;
      }
    }
  }
  return pids;
};

// Waits for the port to close, then ends whatever still holds it (a server started outside zellij, or one
// that ignored its pane closing): TERM, then KILL.
const freePort = async (port, log) => {
  for (let i = 0; i < 20 && (await portOpen(port)); i++) await sleep(250);
  if (!(await portOpen(port))) return;
  for (const signal of ["SIGTERM", "SIGKILL"]) {
    const pids = await portPids(port);
    if (!pids.length) break;
    log(`Port ${port} is still taken; sending ${signal} to ${pids.join(", ")}`);
    pids.forEach((pid) => {
      try {
        process.kill(pid, signal);
      } catch {}
    });
    for (let i = 0; i < 20 && (await portOpen(port)); i++) await sleep(250);
    if (!(await portOpen(port))) return;
  }
  if (await portOpen(port)) throw new Error(`Port ${port} is still in use`);
};

// { stop(name, note), start(name) } for the watcher: replaces a server's pane in place, with a note while
// the switch runs, then with the server again.
export const zellijServers = (project, log = () => {}) => {
  const action = (...args) => capture("zellij", ["--session", project.session, "action", ...args]);

  // A pane's id is found again each time, since replacing a pane gives the new one a new id.
  const findPane = async (name) => {
    const panes = JSON.parse(await action("list-panes", "--json")).filter((p) => !p.is_plugin);
    const match = project.servers[name]?.match;
    return panes.find((p) => p.title === name) ?? (match && panes.find((p) => match.test(`${p.terminal_command ?? ""} ${p.pane_command ?? ""}`)));
  };

  // Replaces a pane with one running `command`, closing the old pane (which ends what ran in it).
  const replace = async (name, command, cwd) => {
    const pane = await findPane(name);
    if (!pane) throw new Error(`No "${name}" pane in zellij session ${project.session}`);
    await action("new-pane", "--in-place", "--pane-id", `terminal_${pane.id}`, "--close-replaced-pane", "--name", name, "--cwd", cwd, "--", ...command);
  };

  return {
    async stop(name, note) {
      const server = project.servers[name];
      await replace(name, ["sh", "-c", `printf '%s\\n' "$1"; exec sleep infinity`, "sh", note], resolve(project.root, server.cwd));
      if (server.port) await freePort(server.port, log);
    },
    // Through bin/keep, as in the layout, so the pane stays when the server stops.
    start: (name) => replace(name, [KEEP, ...keepArgs(project.servers[name].command)], resolve(project.root, project.servers[name].cwd)),
  };
};
