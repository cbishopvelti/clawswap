// The watcher that runs in the zellij session's "clawswap" pane: keeps the branch list fresh (GitHub
// webhook through smee.io), and switches branch when a Stream Deck key or a page asks, over a localhost API.
import { createServer } from "node:http";
import { branchList, currentBranch, fetchOrigin, githubRepo, githubToken, isDirty, mergedBranches, pullRequestReader, remoteBranches } from "./git.mjs";
import { markUpdated } from "./config.mjs";
import { planNotes, planSteps } from "./plan.mjs";
import { capture, stream } from "./run.mjs";
import { listen } from "./smee.mjs";

// Without webhooks (or if smee drops a delivery), look anyway this often.
const FALLBACK_MS = 15 * 60_000;

const log = (text) => console.log(`\x1b[36m[clawswap]\x1b[0m ${text}`);

// `project`: from config.mjs. `servers`: { stop(name, note), start(name) } (zellij.mjs in the session;
// stand-ins in tests). `runStep(step)`: runs one planned step. `exit(code)`: restarts the watcher after a
// switch changed its config.
export const createWatcher = ({ project, smeeUrl, servers, runStep, refreshGit = true, exit = (code) => process.exit(code) }) => {
  const { root, base } = project;
  const serverNames = Object.keys(project.servers);
  const readPulls = pullRequestReader();
  const state = {
    project: project.name,
    base,
    current: undefined, // { branch, sha }
    dirty: false,
    branches: [],
    prs: false, // whether the list comes from open PRs (a GitHub token was found)
    webhook: smeeUrl ? "connecting" : "off", // "off" (no channel set), "connecting" (set, not connected yet or lost), "connected"
    webhookError: undefined, // why the smee.io connection was lost
    refreshedAt: undefined,
    error: undefined,
    // The checkout's branch on origin: how many commits it is ahead of the checkout (undefined when the
    // branch isn't on origin).
    upstream: undefined, // { sha, behind }
    switch: undefined, // { target, pull, phase: "running" | "done" | "failed", step, error, notes }
  };

  let refreshing;
  let again = false;
  const refresh = async () => {
    if (refreshing) {
      again = true;
      return refreshing;
    }
    refreshing = (async () => {
      do {
        again = false;
        try {
          if (refreshGit) await fetchOrigin(root);
          const [remote, current, dirty, merged] = await Promise.all([remoteBranches(root), currentBranch(root), isDirty(root), mergedBranches(root, base).catch(() => new Set())]);
          let pulls;
          const token = await githubToken();
          const repo = token && (await githubRepo(root));
          if (repo) {
            try {
              pulls = await readPulls(repo, token);
            } catch (error) {
              log(`Couldn't read pull requests (${error.message}); showing every branch`);
            }
          }
          const upstreamSha = await capture("git", ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${current.branch}`], { cwd: root }).then((o) => o.trim(), () => undefined);
          const behind = upstreamSha && Number(await capture("git", ["rev-list", "--count", `HEAD..${upstreamSha}`], { cwd: root }));
          const upstream = upstreamSha ? { sha: upstreamSha, behind } : undefined;
          const branches = branchList({ remote, pulls, merged, base, current: current.branch, shortName: project.shortName });
          Object.assign(state, { current, dirty, upstream, branches, prs: !!pulls, refreshedAt: new Date().toISOString(), error: undefined });
        } catch (error) {
          state.error = error.message;
          log(`Refresh failed: ${error.message}`);
        }
      } while (again);
      refreshing = undefined;
    })();
    return refreshing;
  };

  // Webhook deliveries come in bursts (push + pull_request...), so wait a moment and look once.
  let debounce;
  const soon = () => {
    clearTimeout(debounce);
    debounce = setTimeout(refresh, 1500);
  };

  // Refusals are kept in the state too, so the key that was pressed can say why nothing happened.
  const refuse = (run, error, status) => {
    state.switch = { ...run, phase: "failed", error, notes: [], at: Date.now() };
    throw Object.assign(new Error(error), { status });
  };

  const switchTo = async (target) => {
    if (state.switch?.phase === "running") throw Object.assign(new Error(`Already switching to ${state.switch.target}`), { status: 409 });
    await refresh();
    if (!state.branches.some((b) => b.branch === target)) throw Object.assign(new Error(`${target} isn't one of the listed branches`), { status: 404 });
    if (state.dirty) refuse({ target }, "Uncommitted changes: commit or stash them first", 409);
    const run = { target, phase: "running", step: "Stopping servers", notes: [] };
    state.switch = run;
    void doSwitch(run);
    return run;
  };

  // Pulls the checkout's branch: the same as switching to it, except that it works for any branch on
  // origin, and leaves the servers alone when there's nothing new.
  const pull = async () => {
    if (state.switch?.phase === "running") throw Object.assign(new Error(`Already switching to ${state.switch.target}`), { status: 409 });
    await refresh();
    const target = state.current?.branch;
    if (!target || target === "HEAD") refuse({ target, pull: true }, "Not on a branch", 409);
    if (!state.upstream) refuse({ target, pull: true }, `${target} isn't on GitHub`, 404);
    if (!state.upstream.behind) {
      state.switch = { target, pull: true, phase: "done", notes: ["Already up to date"], at: Date.now() };
      return state.switch;
    }
    if (state.dirty) refuse({ target, pull: true }, "Uncommitted changes: commit or stash them first", 409);
    const run = { target, pull: true, phase: "running", step: "Stopping servers", notes: [] };
    state.switch = run;
    void doSwitch(run);
    return run;
  };

  const doSwitch = async (run) => {
    const { target } = run;
    const git = (...args) => capture("git", args, { cwd: root });
    const before = state.current?.sha;
    let changed = [];
    log(run.pull ? `Pulling ${target}` : `Switching to ${target}`);
    try {
      for (const name of serverNames) await servers.stop(name, run.pull ? `Pulling ${target}...` : `Switching to ${target}...`);
      run.step = `Checking out ${target}`;
      const local = await git("rev-parse", "--verify", "--quiet", `refs/heads/${target}`).then(() => true, () => false);
      if (local) {
        await git("checkout", target);
        await git("merge", "--ff-only", `origin/${target}`);
      } else {
        await git("checkout", "-b", target, "--track", `origin/${target}`);
      }
      const after = (await git("rev-parse", "HEAD")).trim();
      changed = before && before !== after ? (await git("diff", "--name-only", before, after)).split("\n").filter(Boolean) : [];
      for (const step of planSteps(project.steps, changed)) {
        run.step = step.label;
        log(step.label);
        await runStep(step);
      }
      run.phase = "done";
      log(`On ${target}`);
      try {
        markUpdated(project, after);
      } catch (error) {
        log(`Couldn't note the update in ${project.localFile}: ${error.message}`);
      }
    } catch (error) {
      Object.assign(run, { phase: "failed", error: `${run.step}: ${error.message}` });
      log(`Failed at ${run.error}`);
    }
    // Start the servers whatever happened, so a failed step doesn't leave you without them.
    for (const name of serverNames) {
      try {
        await servers.start(name);
      } catch (error) {
        if (run.phase !== "failed") Object.assign(run, { phase: "failed", error: `Starting ${name}: ${error.message}` });
        log(`Couldn't start ${name}: ${error.message}`);
      }
    }
    run.step = undefined;
    run.notes.push(...planNotes(project.notes, changed));
    run.notes.forEach(log);
    await refresh();
    if (changed.some(project.restart)) {
      log(`${project.file} changed; restarting the watcher`);
      exit(75);
    }
  };

  const json = (res, status, body, origin) => {
    res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store", ...(origin ? { "Access-Control-Allow-Origin": origin, Vary: "Origin" } : {}) });
    res.end(JSON.stringify(body));
  };

  const server = createServer((req, res) => {
    // Only this machine's pages: a page elsewhere can't make the browser send a JSON POST here without a
    // preflight, which only these origins pass. The Host check stops DNS rebinding.
    const origin = req.headers.origin;
    const allowed = origin && project.origins.has(origin) ? origin : undefined;
    if (!/^(localhost|127\.0\.0\.1)(:\d+)?$/.test(req.headers.host ?? "") || (origin && !allowed)) return json(res, 403, { error: "Forbidden" });
    if (req.method === "OPTIONS") {
      res.writeHead(204, { "Access-Control-Allow-Origin": allowed, "Access-Control-Allow-Methods": "GET, POST", "Access-Control-Allow-Headers": "Content-Type", Vary: "Origin" });
      return res.end();
    }
    const url = new URL(req.url ?? "/", "http://localhost");
    if (req.method === "GET" && url.pathname === "/state") return json(res, 200, state, allowed);
    if (req.method !== "POST" || !(req.headers["content-type"] ?? "").startsWith("application/json")) return json(res, 404, { error: "Not found" }, allowed);
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", async () => {
      try {
        if (url.pathname === "/refresh") {
          await refresh();
          return json(res, 200, state, allowed);
        }
        if (url.pathname === "/switch") {
          const { branch } = JSON.parse(body || "{}");
          await switchTo(String(branch ?? ""));
          return json(res, 202, state, allowed);
        }
        if (url.pathname === "/pull") {
          await pull();
          return json(res, 202, state, allowed);
        }
        json(res, 404, { error: "Not found" }, allowed);
      } catch (error) {
        json(res, error.status ?? 500, { error: error.message }, allowed);
      }
    });
  });

  let stopSmee;
  let fallback;
  return {
    state,
    refresh,
    switchTo,
    pull,
    server,
    async start(port = project.port) {
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, "127.0.0.1", resolve);
      });
      log(`API on http://127.0.0.1:${server.address().port} (${project.name}, base branch ${base})`);
      await refresh();
      if (smeeUrl) {
        stopSmee = listen(smeeUrl, {
          log,
          onOpen: () => {
            state.webhook = "connected";
            state.webhookError = undefined;
            soon(); // anything missed while disconnected
          },
          onDrop: (reason) => {
            state.webhook = "connecting";
            state.webhookError = reason;
          },
          onDelivery: (kind) => {
            log(`GitHub: ${kind}`);
            soon();
          },
        });
      } else {
        log("No smee.io channel set (clawswap smee); looking for new branches every 15 minutes");
      }
      fallback = setInterval(refresh, FALLBACK_MS);
    },
    stop() {
      stopSmee?.();
      clearInterval(fallback);
      clearTimeout(debounce);
      server.close();
    },
  };
};

// The real step runner: output goes to the watcher's pane (or the terminal, for `up` and `update`).
export const stepRunner = (project) => (step) => stream(step.cmd, step.args, { cwd: `${project.root}/${step.cwd}`, prefix: `  ${step.name} | ` });
