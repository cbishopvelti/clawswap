// clawswap's commands. See README.md.
import { spawn } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { CONFIG_FILE, loadProject, markUpdated, pendingSteps, readLocal, writeLocal } from "./config.mjs";
import { repoRoot } from "./git.mjs";
import { planSteps } from "./plan.mjs";
import { capture } from "./run.mjs";
import { newChannel } from "./smee.mjs";
import { createWatcher, stepRunner } from "./watcher.mjs";
import { layout, versionOk, waitForPort, zellijServers, zellijVersion } from "./zellij.mjs";

// Runs steps one after another in this terminal; true when they all worked.
const runSteps = async (project, steps) => {
  const run = stepRunner(project);
  for (const step of steps) {
    console.log(step.label);
    try {
      await run(step);
      if (step.waitForPort) await waitForPort(step.waitForPort);
    } catch (error) {
      console.error(`${step.label} failed: ${error.message}`);
      return false;
    }
  }
  return true;
};

// Runs the config's prepare steps (containers and the like), then brings the checkout up to date with HEAD
// before the servers start, for whatever changed since the steps last ran (a pull or checkout done by
// hand, or a first run).
const catchUp = async (project) => {
  await runSteps(project, project.prepare);
  const { head, steps } = await pendingSteps(project);
  if (!steps.length) return;
  console.log(`Catching up with ${head.slice(0, 7)}: ${steps.map((s) => s.label).join(", ")}`);
  if (await runSteps(project, steps)) markUpdated(project, head);
  else {
    console.error("Starting the servers anyway; fix that and run clawswap update.");
    await new Promise((r) => setTimeout(r, 4000));
  }
};

// The watcher's port, from the config when there is one (status, switch and pull also work from a
// checkout without it, with CLAWSWAP_PORT or the default).
const apiPort = async () => (await loadProject().catch(() => undefined))?.port ?? Number(process.env.CLAWSWAP_PORT || 8790);

const api = async (path, body) => {
  let response;
  try {
    response = await fetch(`http://127.0.0.1:${await apiPort()}${path}`, body ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {});
  } catch {
    throw new Error("The watcher isn't running (start the session with clawswap up)");
  }
  const answer = await response.json();
  if (!response.ok) throw new Error(answer.error);
  return answer;
};

const printState = (s) => {
  console.log(`${s.project}: on ${s.current?.branch}${s.dirty ? " (uncommitted changes)" : ""}; webhook ${s.webhook}`);
  s.branches.forEach((b, i) => console.log(`${String(i + 1).padStart(3)}  ${b.branch === s.current?.branch ? "*" : " "} ${b.branch}${b.pr ? `  #${b.pr.number} ${b.pr.title}` : ""}`));
  if (s.switch) console.log(`Last switch: ${s.switch.target}: ${s.switch.phase}${s.switch.step ? ` (${s.switch.step})` : ""}${s.switch.error ? `: ${s.switch.error}` : ""}`);
};

const STARTER = `// clawswap's settings for this repo. See https://github.com/cbishopvelti/clawswap#configuration
export default {
  // base: "main",            // the branch listed first (default: origin's default branch)
  // port: 8790,              // the watcher's API; give each project its own if you run several

  // The servers a switch stops and starts again, each in its own zellij pane.
  servers: {
    web: { command: "npm run dev", cwd: ".", port: 5173 },
  },

  // Other panes in the session, left running across switches.
  // panes: { logs: { command: "docker compose logs -f" } },

  // Runs before \`clawswap up\` starts a new session.
  // prepare: [{ label: "Starting containers", run: "docker compose up -d", waitForPort: 5432 }],

  // What a switch runs when these files changed, in this order. "dir/" matches anything under it.
  steps: [
    { label: "npm install", when: ["package.json", "package-lock.json"], run: "npm install" },
  ],

  // Said after a switch that changed these files.
  // notes: [{ when: "plugin/", message: "The plugin changed: reload it" }],
};
`;

const commands = {
  // Opens (or attaches to) the zellij session with every server in its own pane.
  async up() {
    const project = await loadProject();
    const version = await zellijVersion().catch(() => undefined);
    if (!versionOk(version)) {
      throw new Error(`clawswap needs zellij 0.44 or newer (found ${version ? version.join(".") : "none"}): https://github.com/zellij-org/zellij/releases`);
    }
    const sessions = await capture("zellij", ["list-sessions", "--no-formatting"]).catch(() => "");
    const line = sessions.split("\n").find((l) => l.split(" ")[0] === project.session);
    // An exited session would come back with its panes waiting for Enter; start it fresh instead.
    if (line?.includes("EXITED")) await capture("zellij", ["delete-session", project.session]).catch(() => {});
    const running = line && !line.includes("EXITED");
    let file = project.layout && resolve(project.root, project.layout);
    if (!running) {
      await catchUp(project);
      if (!file) writeFileSync((file = project.localFile.replace(/\.json$/, ".kdl")), layout(project));
    }
    const args = running ? ["attach", project.session] : ["--session", project.session, "--new-session-with-layout", file];
    await new Promise((done) => spawn("zellij", args, { cwd: project.root, stdio: "inherit" }).on("close", done));
  },

  async watch() {
    const project = await loadProject();
    const watcher = createWatcher({
      project,
      smeeUrl: process.env.CLAWSWAP_SMEE || readLocal(project).smee,
      servers: zellijServers(project, console.log),
      runStep: stepRunner(project),
    });
    await watcher.start();
  },

  async status() {
    printState(await api("/state"));
  },

  async switch(branch) {
    if (!branch) throw new Error("Usage: clawswap switch <branch>");
    await api("/switch", { branch });
    console.log(`Switching to ${branch}; follow it in the clawswap pane`);
  },

  // Pulls the checkout's branch, restarting the servers if anything came in.
  async pull() {
    const state = await api("/pull", {});
    console.log(state.switch.phase === "running" ? `Pulling ${state.switch.target}; follow it in the clawswap pane` : state.switch.notes.join("\n"));
  },

  // Runs the steps by hand: for what changed since they last ran (or since <rev>), or all of them with --all.
  async update(arg) {
    const project = await loadProject();
    const head = (await capture("git", ["rev-parse", "HEAD"], { cwd: project.root })).trim();
    const steps = arg === "--all"
      ? planSteps(project.steps, [], { all: true })
      : arg
        ? planSteps(project.steps, (await capture("git", ["diff", "--name-only", arg, head], { cwd: project.root })).split("\n").filter(Boolean))
        : (await pendingSteps(project)).steps;
    if (steps.length && !(await runSteps(project, steps))) process.exit(1);
    markUpdated(project, head);
    if (!steps.length) console.log("Nothing to do");
  },

  // Makes a smee.io channel for the GitHub webhook and saves it for this checkout.
  async smee(url) {
    const project = await loadProject();
    const channel = url || (await newChannel());
    writeLocal(project, { smee: channel });
    console.log(`Saved ${channel} in ${project.localFile}.

Now add the webhook on GitHub (repo Settings > Webhooks > Add webhook):
  Payload URL:  ${channel}
  Content type: application/json
  Events:       Let me select individual events > Branch or tag creation, Branch or tag deletion,
                Pull requests, Pushes
Then restart the watcher (Ctrl+C in the clawswap pane, then Enter).`);
  },

  // Writes a starter config at the repo root.
  async init() {
    const root = await repoRoot().catch(() => {
      throw new Error("Not in a git checkout");
    });
    const path = `${root}/${CONFIG_FILE}`;
    if (existsSync(path)) throw new Error(`${path} already exists`);
    writeFileSync(path, STARTER);
    console.log(`Wrote ${path}. Fill in your servers and steps, then run clawswap up.`);
  },

  // Prints the zellij layout up opens, to start your own from.
  async layout() {
    process.stdout.write(layout(await loadProject()));
  },
};

const [command = "help", ...args] = process.argv.slice(2);
if (!commands[command]) {
  console.log(`Usage: clawswap <command>
  init             Write a starter ${CONFIG_FILE} in this repo
  up               Start (or attach to) the zellij session with every server
  status           The branches the keys show, and the last switch
  switch <branch>  Switch branch: stop the servers, check out, update, start them again
  pull             Pull the current branch the same way (nothing happens if it's up to date)
  update [rev]     Run the steps for what changed since they last ran (or since rev), or --all
  smee [url]       Set up the smee.io channel for the GitHub webhook
  layout           Print the zellij layout up opens
  watch            The watcher (runs in the session's clawswap pane)`);
  process.exit(command === "help" ? 0 : 1);
}
try {
  await commands[command](...args);
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
