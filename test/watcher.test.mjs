// The watcher against a throwaway origin and clone, with stand-ins for the zellij panes and update steps.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import bmx from "../examples/bmx.config.mjs";
import { createWatcher } from "../lib/watcher.mjs";
import { loadProject, markUpdated, normalise, pendingSteps } from "../lib/config.mjs";

const sh = (cwd, ...args) => execFileSync("git", args, { cwd, encoding: "utf8", env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } });

const setup = () => {
  const dir = mkdtempSync(`${tmpdir()}/clawswap-`);
  const work = `${dir}/work`;
  sh(dir, "init", "-q", "--bare", "-b", "claude-main", "origin.git");
  sh(dir, "clone", "-q", "origin.git", "work");
  mkdirSync(`${work}/frontend`);
  writeFileSync(`${work}/frontend/package.json`, "{}\n");
  sh(work, "add", ".");
  sh(work, "commit", "-qm", "base");
  sh(work, "push", "-q", "origin", "claude-main");
  // A feature branch that changes the frontend's deps and the schema.
  sh(work, "checkout", "-qb", "claude/new-thing");
  writeFileSync(`${work}/frontend/package.json`, '{"dependencies":{}}\n');
  mkdirSync(`${work}/surrealdb`);
  writeFileSync(`${work}/surrealdb/schema.surql`, "DEFINE TABLE x;\n");
  sh(work, "add", ".");
  sh(work, "commit", "-qm", "feature");
  sh(work, "push", "-q", "origin", "claude/new-thing");
  sh(work, "checkout", "-q", "claude-main");
  sh(work, "branch", "-qD", "claude/new-thing");
  return { dir, work, project: normalise(bmx, { root: work, localFile: `${work}/.git/clawswap.json` }) };
};

const until = async (check) => {
  const deadline = Date.now() + 5000;
  while (!check()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 20));
  }
};

const post = (port, path, body = {}) => fetch(`http://127.0.0.1:${port}${path}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

// No gh in PATH, so the list is every branch.
const withoutGh = async (fn) => {
  const path = process.env.PATH;
  const token = process.env.GITHUB_TOKEN;
  process.env.PATH = "/usr/bin:/bin";
  delete process.env.GITHUB_TOKEN;
  try {
    await fn();
  } finally {
    process.env.PATH = path;
    if (token !== undefined) process.env.GITHUB_TOKEN = token;
  }
};

test("lists branches, switches, runs only the needed steps and restarts the servers", async () => {
  const { dir, work, project } = setup();
  const calls = [];
  const watcher = createWatcher({
    project,
    servers: { stop: async (name) => calls.push(`stop ${name}`), start: async (name) => calls.push(`start ${name}`) },
    runStep: async (step) => calls.push(step.name),
    exit: () => calls.push("exit"),
  });
  try {
    await withoutGh(async () => {
      await watcher.start(0);
      const port = watcher.server.address().port;
      const state = await (await fetch(`http://127.0.0.1:${port}/state`)).json();
      assert.deepEqual(state.branches.map((b) => b.branch), ["claude-main", "claude/new-thing"]);
      assert.equal(state.branches[1].short, "new-thing");
      assert.equal(state.current.branch, "claude-main");
      assert.equal(state.project, "bmx");

      assert.equal((await post(port, "/switch", { branch: "claude/new-thing" })).status, 202);
      await until(() => watcher.state.switch.phase !== "running" && calls.includes("start vite"));
      assert.equal(watcher.state.switch.phase, "done");
      assert.deepEqual(calls, ["stop phx", "stop vite", "npm", "schema", "access", "start phx", "start vite"]);
      await until(() => watcher.state.current?.branch === "claude/new-thing");

      // An unknown branch is refused, and so is a switch with uncommitted changes.
      assert.equal((await post(port, "/switch", { branch: "nope" })).status, 404);
      writeFileSync(`${work}/frontend/package.json`, "{ }\n");
      const dirty = await post(port, "/switch", { branch: "claude-main" });
      assert.equal(dirty.status, 409);
      assert.match((await dirty.json()).error, /Uncommitted/);
    });
  } finally {
    watcher.stop();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("restarts itself after a switch that changed the config", async () => {
  const { dir, work, project } = setup();
  writeFileSync(`${work}/clawswap.config.mjs`, "export default {};\n");
  sh(work, "add", ".");
  sh(work, "commit", "-qm", "config");
  sh(work, "push", "-q", "origin", "claude-main:claude/config");
  sh(work, "reset", "-q", "--hard", "HEAD~1");
  const calls = [];
  const watcher = createWatcher({ project, servers: { stop: async () => {}, start: async () => {} }, runStep: async () => {}, exit: (code) => calls.push(code) });
  try {
    await withoutGh(async () => {
      await watcher.start(0);
      await watcher.switchTo("claude/config");
      await until(() => calls.length);
      assert.deepEqual(calls, [75]);
    });
  } finally {
    watcher.stop();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("only answers this machine's pages", async () => {
  const project = normalise(bmx, { root: process.cwd() });
  const watcher = createWatcher({ project, servers: {}, runStep: async () => {}, refreshGit: false });
  watcher.server.listen(0, "127.0.0.1");
  await new Promise((r) => watcher.server.once("listening", r));
  const port = watcher.server.address().port;
  try {
    const other = await fetch(`http://127.0.0.1:${port}/state`, { headers: { Origin: "https://example.com" } });
    assert.equal(other.status, 403);
    const vite = await fetch(`http://127.0.0.1:${port}/state`, { headers: { Origin: "http://localhost:5173" } });
    assert.equal(vite.headers.get("access-control-allow-origin"), "http://localhost:5173");
  } finally {
    watcher.stop();
  }
});

test("catches up from the last updated commit, or runs everything the first time", async () => {
  const { dir, work, project } = setup();
  try {
    assert.equal((await pendingSteps(project)).steps.length, 6);
    const head = sh(work, "rev-parse", "HEAD").trim();
    markUpdated(project, head);
    assert.deepEqual((await pendingSteps(project)).steps, []);
    mkdirSync(`${work}/backend`);
    writeFileSync(`${work}/backend/mix.lock`, "%{}\n");
    sh(work, "add", "backend");
    sh(work, "commit", "-qm", "deps");
    assert.deepEqual((await pendingSteps(project)).steps.map((s) => s.name), ["deps"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loads the repo's config, with state kept in .git", async () => {
  const { dir, work } = setup();
  try {
    await assert.rejects(loadProject(`${work}/frontend`), /No clawswap\.config\.mjs/);
    copyFileSync(new URL("../examples/bmx.config.mjs", import.meta.url), `${work}/clawswap.config.mjs`);
    const project = await loadProject(`${work}/frontend`);
    assert.equal(project.root, sh(work, "rev-parse", "--show-toplevel").trim());
    assert.equal(project.base, "claude-main");
    assert.equal(project.localFile, `${project.root}/.git/clawswap.json`);
    assert.deepEqual(Object.keys(project.servers), ["phx", "vite"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("pulls the checkout's branch, and leaves the servers alone when there's nothing new", async () => {
  const { dir, project } = setup();
  const calls = [];
  const watcher = createWatcher({
    project,
    servers: { stop: async (name) => calls.push(`stop ${name}`), start: async (name) => calls.push(`start ${name}`) },
    runStep: async (step) => calls.push(step.name),
    exit: () => {},
  });
  try {
    await withoutGh(async () => {
      await watcher.start(0);
      const port = watcher.server.address().port;

      const nothing = await (await post(port, "/pull")).json();
      assert.deepEqual(nothing.switch.notes, ["Already up to date"]);
      assert.deepEqual(calls, []);

      // Someone else pushes a deps change to claude-main.
      sh(dir, "clone", "-q", "origin.git", "other");
      mkdirSync(`${dir}/other/backend`);
      writeFileSync(`${dir}/other/backend/mix.lock`, "%{}\n");
      sh(`${dir}/other`, "add", ".");
      sh(`${dir}/other`, "commit", "-qm", "deps");
      sh(`${dir}/other`, "push", "-q", "origin", "claude-main");

      assert.equal((await post(port, "/pull")).status, 202);
      assert.equal(watcher.state.upstream.behind, 1);
      await until(() => watcher.state.switch.phase !== "running" && calls.includes("start vite"));
      assert.equal(watcher.state.switch.phase, "done");
      assert.deepEqual(calls, ["stop phx", "stop vite", "deps", "start phx", "start vite"]);
      await until(() => watcher.state.upstream?.behind === 0);
    });
  } finally {
    watcher.stop();
    rmSync(dir, { recursive: true, force: true });
  }
});
