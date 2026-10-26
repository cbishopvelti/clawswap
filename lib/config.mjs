// The project clawswap runs: its clawswap.config.mjs (committed, at the repo root), and the per-checkout
// state in .git/clawswap.json (the smee.io channel, and the commit the steps last ran for, so `up` can catch
// up a checkout that moved while clawswap wasn't watching).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import { pathToFileURL } from "node:url";
import { capture } from "./run.mjs";
import { defaultBase, gitPath, repoRoot } from "./git.mjs";
import { matcher, normaliseStep, planSteps } from "./plan.mjs";

export const CONFIG_FILE = "clawswap.config.mjs";

const serverOrigins = (servers) =>
  Object.values(servers)
    .filter((s) => s.port)
    .flatMap((s) => [`http://localhost:${s.port}`, `http://127.0.0.1:${s.port}`]);

// The config as the rest of clawswap uses it, with the defaults filled in. See README.md for each field.
export const normalise = (config, { root, file = CONFIG_FILE, base, localFile = `${root}/.git/clawswap.json` }) => {
  const servers = Object.fromEntries(
    Object.entries(config.servers ?? {}).map(([name, s]) => {
      if (!s.command) throw new Error(`Server ${name} has no command`);
      return [name, { command: s.command, cwd: s.cwd ?? ".", port: s.port, match: s.match }];
    }),
  );
  const panes = Object.fromEntries(Object.entries(config.panes ?? {}).map(([name, p]) => [name, { command: p.command, cwd: p.cwd ?? "." }]));
  for (const name of Object.keys(panes)) if (servers[name] || name === "clawswap") throw new Error(`Pane name ${name} is taken`);
  return {
    root,
    file,
    localFile,
    name: config.name ?? basename(root),
    session: process.env.CLAWSWAP_SESSION || config.session || config.name || basename(root),
    base: process.env.CLAWSWAP_BASE || config.base || base || "main",
    port: Number(process.env.CLAWSWAP_PORT || config.port || 8790),
    // Pages allowed to call the API from a browser: the servers' own, and any the config adds.
    origins: new Set([...serverOrigins(servers), ...(config.origins ?? [])]),
    servers,
    panes,
    layout: config.layout,
    prepare: (config.prepare ?? []).map(normaliseStep),
    steps: (config.steps ?? []).map(normaliseStep),
    notes: (config.notes ?? []).map((n) => ({ message: n.message, test: matcher(n.when) })),
    // A switch that changes these restarts the watcher, so it runs the new config (and, for a copy of
    // clawswap kept in the repo, the new code).
    restart: matcher([file, ...[].concat(config.restartWhen ?? [])]),
    shortName: config.shortName ?? ((branch) => branch.replace(/^claude\//, "")),
  };
};

// Finds the repo from `cwd` and loads its config (CLAWSWAP_CONFIG names another file).
export const loadProject = async (cwd = process.cwd()) => {
  const root = await repoRoot(cwd).catch(() => {
    throw new Error("Not in a git checkout");
  });
  const file = process.env.CLAWSWAP_CONFIG || CONFIG_FILE;
  const path = file.startsWith("/") ? file : `${root}/${file}`;
  if (!existsSync(path)) throw new Error(`No ${file} in ${root} (clawswap init writes one)`);
  const config = (await import(pathToFileURL(path).href)).default;
  return normalise(config ?? {}, { root, file, base: await defaultBase(root), localFile: await gitPath(root, "clawswap.json") });
};

export const readLocal = (project) => {
  try {
    return JSON.parse(readFileSync(project.localFile, "utf8"));
  } catch {
    return {};
  }
};

export const writeLocal = (project, changes) => writeFileSync(project.localFile, JSON.stringify({ ...readLocal(project), ...changes }, null, 2) + "\n");

// Remembers that the steps have run for this commit.
export const markUpdated = (project, sha) => writeLocal(project, { updated: sha });

// The steps HEAD still needs: those for what changed since the last updated commit, or all of them when
// there's none (a first run) or it's no longer known to git.
export const pendingSteps = async (project) => {
  const { root, steps } = project;
  const head = (await capture("git", ["rev-parse", "HEAD"], { cwd: root })).trim();
  const last = readLocal(project).updated;
  if (last === head) return { head, steps: [] };
  const changed = last && (await capture("git", ["diff", "--name-only", last, head], { cwd: root }).catch(() => undefined));
  return { head, steps: changed === undefined || !last ? planSteps(steps, [], { all: true }) : planSteps(steps, changed.split("\n").filter(Boolean)) };
};
