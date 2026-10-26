import { test } from "node:test";
import assert from "node:assert/strict";
import { assign, createBranchKeys, keyLook, pullLook, wrap } from "../dev.clawswap.sdPlugin/bin/branches.mjs";

const state = {
  current: { branch: "claude-main", sha: "1" },
  dirty: false,
  branches: [
    { branch: "claude-main", short: "claude-main", sha: "1" },
    { branch: "claude/undo-sliders-abc123", short: "undo-sliders-abc123", sha: "2", pr: { number: 41, title: "Undo for sliders" } },
    { branch: "claude/streamdeck-branch-switcher", short: "streamdeck-branch-switcher", sha: "3" },
  ],
};

const image = (sent, context) => decodeURIComponent(sent.filter((m) => m.event === "setImage" && m.context === context).at(-1).payload.image);

test("keys on next branch take the list in deck order; named keys show their branch", () => {
  const instances = new Map([
    ["b", { settings: {}, coordinates: { row: 0, column: 1 } }],
    ["a", { settings: {}, coordinates: { row: 0, column: 0 } }],
    ["pinned", { settings: { branch: "claude/streamdeck-branch-switcher" }, coordinates: { row: 0, column: 2 } }],
    ["c", { settings: {}, coordinates: { row: 1, column: 0 } }],
  ]);
  const shown = assign(instances, state.branches);
  assert.equal(shown.get("a").branch, "claude-main");
  assert.equal(shown.get("b").branch, "claude/undo-sliders-abc123");
  assert.equal(shown.get("c").branch, "claude/streamdeck-branch-switcher");
  assert.equal(shown.get("pinned").branch, "claude/streamdeck-branch-switcher");
});

test("a key says what its branch is doing", () => {
  assert.equal(keyLook(state, state.branches[0]).status, "Current");
  assert.deepEqual(keyLook(state, state.branches[1]), { title: "Undo for sliders", number: 41 });
  assert.equal(keyLook(state, state.branches[2]).title, "streamdeck-branch-switcher");
  assert.equal(keyLook(state, { branch: "feature/x", sha: "9" }).title, "feature/x");
  const switching = { ...state, switch: { target: "claude/undo-sliders-abc123", phase: "running", step: "npm install" } };
  assert.equal(keyLook(switching, state.branches[1]).status, "npm install");
  const behind = { ...state, current: { branch: "claude-main", sha: "0" } };
  assert.equal(keyLook(behind, state.branches[0]).status, "New commits");
});

test("wraps titles into a few short lines", () => {
  assert.deepEqual(wrap("Undo for sliders and macros too", 11, 3), ["Undo for", "sliders and", "macros too"]);
  assert.deepEqual(wrap("streamdeck-branch-switcher", 11, 3), ["streamdeck-", "branch-", "switcher"]);
  assert.equal(wrap("a b c d e f g h i j k l m n o p q r s t u v w x y z", 5, 2)[1].endsWith("…"), true);
});

test("draws keys from the watcher and posts presses to it", async () => {
  const sent = [];
  const requests = [];
  const fetchImpl = async (url, init) => {
    requests.push({ url, body: init?.body });
    return { ok: true, json: async () => state };
  };
  const keys = createBranchKeys({ send: (m) => sent.push(m), fetchImpl, url: "http://dev", setTimer: () => 0, clearTimer: () => {} });
  keys.handle({ event: "willAppear", context: "a", payload: { settings: {}, coordinates: { row: 0, column: 0 } } });
  await keys.poll();
  assert.match(image(sent, "a"), /claude-main/);
  await keys.handle({ event: "keyDown", context: "a", payload: {} });
  assert.deepEqual(requests.at(-1), { url: "http://dev/switch", body: JSON.stringify({ branch: "claude-main" }) });
});

test("keys on different watchers get their own lists", async () => {
  const other = { current: { branch: "main", sha: "7" }, branches: [{ branch: "main", short: "main", sha: "7" }, { branch: "fix", short: "fix", sha: "8" }] };
  const sent = [];
  const requests = [];
  const fetchImpl = async (url, init) => {
    requests.push({ url, body: init?.body });
    return { ok: true, json: async () => (url.startsWith("http://shop") ? other : state) };
  };
  const keys = createBranchKeys({ send: (m) => sent.push(m), fetchImpl, url: "http://dev", setTimer: () => 0, clearTimer: () => {} });
  keys.handle({ event: "willAppear", context: "a", payload: { settings: {}, coordinates: { row: 0, column: 0 } } });
  keys.handle({ event: "willAppear", context: "s1", payload: { settings: { url: "http://shop/" }, coordinates: { row: 0, column: 1 } } });
  keys.handle({ event: "willAppear", context: "s2", payload: { settings: { url: "http://shop" }, coordinates: { row: 0, column: 2 } } });
  await keys.poll();
  assert.match(image(sent, "a"), /claude-main/);
  assert.match(image(sent, "s1"), />main</);
  assert.match(image(sent, "s2"), />fix</);
  await keys.handle({ event: "keyDown", context: "s2", payload: {} });
  assert.deepEqual(requests.at(-1), { url: "http://shop/switch", body: JSON.stringify({ branch: "fix" }) });
});

test("says when the watcher isn't running", async () => {
  const sent = [];
  const keys = createBranchKeys({ send: (m) => sent.push(m), fetchImpl: async () => { throw new Error("refused"); }, setTimer: () => 0, clearTimer: () => {} });
  keys.handle({ event: "willAppear", context: "a", payload: { settings: {}, coordinates: { row: 0, column: 0 } } });
  await keys.poll();
  assert.match(image(sent, "a"), /Not running/);
});

test("a pull key shows the checkout's branch and what GitHub has for it, and posts /pull", async () => {
  assert.deepEqual(pullLook({ ...state, upstream: { sha: "1", behind: 0 } }), { title: "Pull claude-main", status: "Up to date" });
  assert.equal(pullLook({ ...state, current: { branch: "claude/undo-sliders-abc123" }, upstream: { sha: "1", behind: 0 } }).title, "Pull undo-sliders-abc123");
  assert.equal(pullLook({ ...state, upstream: { sha: "9", behind: 3 } }).status, "3 new commits");
  assert.equal(pullLook({ ...state, upstream: undefined }).status, "Not on GitHub");
  assert.equal(pullLook({ ...state, upstream: { sha: "9", behind: 1 }, switch: { target: "claude-main", pull: true, phase: "running", step: "mix deps.get" } }).status, "mix deps.get");

  const sent = [];
  const requests = [];
  const upToDate = { ...state, upstream: { sha: "1", behind: 0 }, switch: { target: "claude-main", pull: true, phase: "done", notes: ["Already up to date"] } };
  const fetchImpl = async (url, init) => {
    requests.push({ url, body: init?.body });
    return { ok: true, json: async () => upToDate };
  };
  const keys = createBranchKeys({ send: (m) => sent.push(m), fetchImpl, url: "http://dev", setTimer: () => 0, clearTimer: () => {} });
  // A pull key doesn't take a branch from the list, so the branch key next to it still shows the first one.
  keys.handle({ event: "willAppear", action: "dev.clawswap.pull", context: "p", payload: { settings: {}, coordinates: { row: 0, column: 0 } } });
  keys.handle({ event: "willAppear", action: "dev.clawswap.branch", context: "b", payload: { settings: {}, coordinates: { row: 0, column: 1 } } });
  await keys.poll();
  assert.match(image(sent, "b"), /claude-main/);
  await keys.handle({ event: "keyDown", context: "p", payload: {} });
  assert.deepEqual(requests.at(-1), { url: "http://dev/pull", body: "{}" });
  assert.ok(sent.some((m) => m.event === "showOk" && m.context === "p"));
});
