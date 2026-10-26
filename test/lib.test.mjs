import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import bmx from "../examples/bmx.config.mjs";
import { normalise } from "../lib/config.mjs";
import { branchList } from "../lib/git.mjs";
import { matcher, planNotes, planSteps } from "../lib/plan.mjs";
import { listen, parseEvents } from "../lib/smee.mjs";
import { layout, versionOk } from "../lib/zellij.mjs";

const project = normalise(bmx, { root: "/work/bmx" });

test("plans only the steps the changed files need, in the config's order", () => {
  const names = (changed) => planSteps(project.steps, changed).map((s) => s.name);
  assert.deepEqual(names(["frontend/src/app.tsx"]), []);
  assert.deepEqual(names(["frontend/package-lock.json", "backend/mix.lock"]), ["npm", "deps"]);
  assert.deepEqual(names(["surrealdb/schema.surql", "beat-tracker/src/server.js"]), ["docker", "schema", "access"]);
  assert.deepEqual(names(["backend/priv/repo/migrations/1_x.exs"]), ["migrate"]);
  assert.equal(planSteps(project.steps, [], { all: true }).length, 6);
});

test("runs a string through sh and an array as it is", () => {
  const [npm] = planSteps(project.steps, ["frontend/package.json"]);
  assert.deepEqual(npm, { name: "npm", label: "npm install", cmd: "sh", args: ["-c", "npm install"], cwd: "frontend" });
  const [step] = planSteps(normalise({ steps: [{ run: ["mix", "deps.get"], when: "mix.lock" }] }, { root: "/r" }).steps, ["mix.lock"]);
  assert.deepEqual(step, { name: "mix", label: "mix deps.get", cmd: "mix", args: ["deps.get"], cwd: "." });
});

test("matches paths by RegExp, exact path, folder or function", () => {
  const m = matcher([/\.lock$/, "a/b.json", "dir/", (p) => p === "f"]);
  assert.deepEqual(["x.lock", "a/b.json", "a/b.jsonx", "dir/x/y", "dirx/y", "f"].map(m), [true, true, false, true, false, true]);
  assert.equal(matcher(undefined)("anything"), false);
});

test("fills in the defaults", () => {
  const p = normalise({ servers: { web: { command: "npm run dev", port: 3000 } } }, { root: "/home/me/shop", base: "trunk" });
  assert.equal(p.name, "shop");
  assert.equal(p.session, "shop");
  assert.equal(p.base, "trunk");
  assert.equal(p.port, 8790);
  assert.deepEqual([...p.origins], ["http://localhost:3000", "http://127.0.0.1:3000"]);
  assert.equal(p.shortName("claude/fix-it"), "fix-it");
  assert.equal(p.restart("clawswap.config.mjs"), true);
  assert.throws(() => normalise({ servers: { a: { command: "x" } }, panes: { a: { command: "y" } } }, { root: "/r" }), /taken/);
});

test("notes for what changed", () => {
  assert.deepEqual(planNotes(project.notes, ["opendeck-plugin/dev.bmx.deck.sdPlugin/bin/plugin.mjs"]), ["The OpenDeck plugin changed: restart OpenDeck to load it"]);
  assert.deepEqual(planNotes(project.notes, ["frontend/x"]), []);
});

test("writes a layout with the servers, the watcher and the other panes", () => {
  const kdl = layout(project);
  for (const name of ["phx", "vite", "clawswap", "docker"]) assert.match(kdl, new RegExp(`pane name="${name}"`));
  assert.match(kdl, /cwd="\/work\/bmx\/backend" focus=true/);
  assert.match(kdl, /args "iex -S mix phx\.server"/);
  assert.match(kdl, /bin\/clawswap\.mjs" "watch"/);
  // Quotes in commands survive.
  assert.match(layout(normalise({ panes: { q: { command: 'echo "hi"' } } }, { root: "/r" })), /args "echo \\"hi\\""/);
});

test("lists the base first, then open PRs by last update, else branches by newest commit", () => {
  const remote = [
    { branch: "claude/b", sha: "2", date: "2026-10-25" },
    { branch: "claude-main", sha: "1", date: "2026-10-24" },
    { branch: "claude/a", sha: "3", date: "2026-10-23" },
    { branch: "claude/merged", sha: "4", date: "2026-10-20" },
  ];
  const base = "claude-main";
  assert.deepEqual(branchList({ remote, base, current: "claude-main" }).map((b) => b.branch), ["claude-main", "claude/b", "claude/a", "claude/merged"]);
  const pulls = new Map([
    ["claude/b", { number: 2, title: "B", updatedAt: "2026-10-24T00:00:00Z" }],
    ["claude/a", { number: 1, title: "A", updatedAt: "2026-10-25T00:00:00Z" }],
  ]);
  const list = branchList({ remote, pulls, base, current: "claude/merged", shortName: project.shortName });
  assert.deepEqual(list.map((b) => b.branch), ["claude-main", "claude/merged", "claude/a", "claude/b"]);
  assert.deepEqual(list[2].pr, { number: 1, title: "A", updatedAt: "2026-10-25T00:00:00Z" });
  assert.equal(list[2].short, "a");
});

test("marks branches already merged into the base", () => {
  const remote = [{ branch: "main", sha: "1" }, { branch: "done", sha: "2" }, { branch: "new", sha: "3" }];
  const list = branchList({ remote, base: "main", merged: new Set(["main", "done"]) });
  assert.deepEqual(list.map((b) => [b.branch, !!b.merged]), [["main", false], ["done", true], ["new", false]]);
});

test("parses server-sent events across chunks", () => {
  const first = parseEvents("event: ready\ndata: {}\n\ndata: {\"x-github-event\":");
  assert.deepEqual(first.events, [{ event: "ready", data: "{}" }]);
  const second = parseEvents(`${first.rest}"push"}\n\n: comment\n\n`);
  assert.deepEqual(second.events, [{ event: "message", data: '{"x-github-event":"push"}' }, { event: "message", data: "" }]);
});

test("hears webhook deliveries from a smee-style stream", async () => {
  const server = createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    res.write("event: ready\ndata: {}\n\n");
    res.write(`data: ${JSON.stringify({ "x-github-event": "create", body: { ref: "claude/x" } })}\n\n`);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const got = [];
  let opened = 0;
  const stop = listen(`http://127.0.0.1:${server.address().port}/chan`, { onDelivery: (k) => got.push(k), onOpen: () => opened++ });
  const deadline = Date.now() + 3000;
  while (!got.length && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
  stop();
  server.closeAllConnections();
  server.close();
  assert.equal(opened, 1);
  assert.deepEqual(got, ["create"]);
});

test("needs zellij 0.44 or newer", () => {
  assert.equal(versionOk([0, 43, 1]), false);
  assert.equal(versionOk([0, 44, 0]), true);
  assert.equal(versionOk([1, 0, 0]), true);
  assert.equal(versionOk(undefined), false);
});
