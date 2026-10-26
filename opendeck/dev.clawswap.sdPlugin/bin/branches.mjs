// The "clawswap branch" action: each key shows a branch from a clawswap watcher (the base branch, then the
// newest open PRs) and switches to it when pressed; "clawswap pull" pulls whatever branch the checkout is
// on. Each key names its watcher's URL, so one deck can drive several projects. See ../../README.md.

export const BRANCH_ACTION = "dev.clawswap.branch";
export const PULL_ACTION = "dev.clawswap.pull";
export const DEFAULT_URL = "http://127.0.0.1:8790";
const POLL_MS = 1000;
const RETRY_MS = 3000;
// A failed switch stays on its key this long.
const FAILED_MS = 60_000;

const escapeXml = (text) => text.replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" })[c]);

// Up to `lines` lines of about `width` characters, breaking at spaces, slashes and dashes.
export const wrap = (text, width, lines) => {
  const words = text.match(/[^\s/-]+[\s/-]*/g) ?? [];
  const out = [""];
  for (const word of words) {
    const line = out[out.length - 1];
    if (line && (line + word).trimEnd().length > width) out.push(word);
    else out[out.length - 1] = line + word;
  }
  const kept = out.map((l) => l.trimEnd()).map((l) => (l.length > width ? `${l.slice(0, width - 1)}…` : l));
  if (kept.length > lines) {
    kept.length = lines;
    kept[lines - 1] = `${kept[lines - 1].slice(0, width - 1)}…`;
  }
  return kept;
};

const COLOURS = { current: "#3fb950", switching: "#e3b341", failed: "#e0503f", behind: "#58a6ff" };

// One key: a coloured bar for its state, the PR number, the title (or branch name), and a status line.
export const branchImage = ({ title, number, status, bar }) => {
  const lines = wrap(title, 11, number ? 3 : 4);
  const top = number ? 52 : 34;
  const text = lines.map((l, i) => `<text x="10" y="${top + i * 21}" font-family="sans-serif" font-size="18" font-weight="600" fill="#eef1f5">${escapeXml(l)}</text>`).join("");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 144 144"><rect width="144" height="144" fill="#20242c"/>${bar ? `<rect width="144" height="10" fill="${bar}"/>` : ""}${number ? `<text x="10" y="30" font-family="sans-serif" font-size="16" fill="#a3abb8">#${number}</text>` : ""}${text}${status ? `<text x="10" y="132" font-family="sans-serif" font-size="14" fill="${bar ?? "#a3abb8"}">${escapeXml(status.slice(0, 16))}</text>` : ""}</svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
};

// The watcher gives each branch the short name its config wants on keys.
const shortName = (entry) => entry.short ?? entry.branch;

// What a key shows for `entry` (a branch from the watcher's state), or for no branch at all.
export const keyLook = (state, entry) => {
  if (!entry) return { title: "No branch", status: "" };
  const look = { title: entry.pr?.title ?? shortName(entry), number: entry.pr?.number };
  const run = state.switch;
  const isCurrent = state.current?.branch === entry.branch;
  if (run?.target === entry.branch && run.phase === "running") return { ...look, bar: COLOURS.switching, status: run.step ?? "Switching" };
  if (run?.target === entry.branch && run.phase === "failed" && Date.now() - (run.at ?? 0) < FAILED_MS) return { ...look, bar: COLOURS.failed, status: "Failed" };
  if (isCurrent && entry.sha && state.current.sha !== entry.sha) return { ...look, bar: COLOURS.behind, status: "New commits" };
  if (isCurrent) return { ...look, bar: COLOURS.current, status: state.dirty ? "Uncommitted" : "Current" };
  return look;
};

// What a pull key shows: the checkout's branch and whether GitHub has anything new for it.
export const pullLook = (state) => {
  const branch = state.current?.branch;
  const short = branch && (state.branches?.find((b) => b.branch === branch)?.short ?? branch);
  const look = { title: `Pull ${short ?? ""}`.trim() };
  const run = state.switch;
  if (run?.pull && run.target === branch && run.phase === "running") return { ...look, bar: COLOURS.switching, status: run.step ?? "Pulling" };
  if (run?.pull && run.target === branch && run.phase === "failed" && Date.now() - (run.at ?? 0) < FAILED_MS) return { ...look, bar: COLOURS.failed, status: "Failed" };
  if (!state.upstream) return { ...look, status: "Not on GitHub" };
  const n = state.upstream.behind;
  if (n) return { ...look, bar: COLOURS.behind, status: `${n} new commit${n === 1 ? "" : "s"}` };
  return { ...look, status: "Up to date" };
};

// Which branch each key shows: keys on "next branch" take the list in deck order (row by row), the first
// one the base branch; keys set to a branch name show that branch. `instances` are one watcher's keys.
export const assign = (instances, branches) => {
  const auto = [...instances.entries()]
    .filter(([, i]) => !i.pull && !i.settings.branch)
    .sort(([, a], [, b]) => (a.coordinates?.row ?? 0) - (b.coordinates?.row ?? 0) || (a.coordinates?.column ?? 0) - (b.coordinates?.column ?? 0));
  const result = new Map();
  auto.forEach(([context], n) => result.set(context, branches[n]));
  instances.forEach((i, context) => {
    if (!i.pull && i.settings.branch) result.set(context, branches.find((b) => b.branch === i.settings.branch) ?? { branch: i.settings.branch, missing: true });
  });
  return result;
};

const urlOf = (instance, fallback) => (instance.settings.url?.trim() || fallback).replace(/\/+$/, "");

// send: posts one event to OpenDeck. `url`: the watcher for keys that don't name one.
export const createBranchKeys = ({ send, fetchImpl = fetch, url = DEFAULT_URL, setTimer = setTimeout, clearTimer = clearTimeout, log = () => {} }) => {
  const instances = new Map(); // context -> { settings, coordinates, pull, image }
  const watchers = new Map(); // url -> { state, error }
  let shown = new Map(); // context -> branch entry
  let timer;

  const setImage = (instance, context, image) => {
    if (image === instance.image) return;
    instance.image = image;
    send({ event: "setImage", context, payload: { image, target: 0 } });
  };

  const groups = () => {
    const byUrl = new Map();
    instances.forEach((instance, context) => {
      const u = urlOf(instance, url);
      if (!byUrl.has(u)) byUrl.set(u, new Map());
      byUrl.get(u).set(context, instance);
    });
    return byUrl;
  };

  const draw = () => {
    shown = new Map();
    groups().forEach((group, u) => {
      const { state, error } = watchers.get(u) ?? {};
      if (!state) {
        group.forEach((instance, context) => setImage(instance, context, branchImage({ title: "clawswap", status: error ?? "Connecting", bar: error ? COLOURS.failed : undefined })));
        return;
      }
      assign(group, state.branches ?? []).forEach((entry, context) => shown.set(context, entry));
      group.forEach((instance, context) => {
        const entry = shown.get(context);
        const look = instance.pull ? pullLook(state) : entry?.missing ? { title: entry.branch, status: "Not listed" } : keyLook(state, entry);
        setImage(instance, context, branchImage(look));
      });
    });
  };

  const schedule = (ms) => {
    clearTimer(timer);
    timer = instances.size ? setTimer(poll, ms) : undefined;
  };

  async function poll() {
    let failed = false;
    await Promise.all(
      [...groups().keys()].map(async (u) => {
        try {
          const response = await fetchImpl(`${u}/state`);
          watchers.set(u, { state: await response.json() });
        } catch {
          if (watchers.get(u)?.error !== "Not running") log(`clawswap at ${u}: not running`);
          watchers.set(u, { error: "Not running" });
          failed = true;
        }
      }),
    );
    draw();
    schedule(failed ? RETRY_MS : POLL_MS);
  }

  const press = async (context) => {
    const instance = instances.get(context);
    const entry = shown.get(context);
    if (!instance || (!instance.pull && (!entry || entry.missing))) return send({ event: "showAlert", context });
    const u = urlOf(instance, url);
    try {
      const response = instance.pull
        ? await fetchImpl(`${u}/pull`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })
        : await fetchImpl(`${u}/switch`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ branch: entry.branch }) });
      const answer = await response.json();
      if (!response.ok) {
        log(`clawswap: ${answer.error}`);
        send({ event: "showAlert", context });
      } else if (instance.pull && answer.switch?.phase === "done") {
        // Nothing new: a tick, since the key doesn't change.
        send({ event: "showOk", context });
      }
    } catch {
      send({ event: "showAlert", context });
    }
    schedule(0);
  };

  return {
    handle(message) {
      const { event, context, payload } = message;
      switch (event) {
        case "willAppear":
          instances.set(context, { settings: payload.settings ?? {}, coordinates: payload.coordinates, pull: message.action === PULL_ACTION });
          send({ event: "setTitle", context, payload: { title: "", target: 0 } });
          draw();
          schedule(0);
          return;
        case "willDisappear":
          instances.delete(context);
          if (!instances.size) clearTimer(timer);
          else draw();
          return;
        case "didReceiveSettings": {
          const instance = instances.get(context);
          if (instance) Object.assign(instance, { settings: payload.settings ?? {}, coordinates: payload.coordinates ?? instance.coordinates, image: undefined });
          draw();
          schedule(0);
          return;
        }
        case "keyDown":
          return press(context);
      }
    },
    poll,
  };
};
