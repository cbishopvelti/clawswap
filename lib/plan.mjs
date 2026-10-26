// What has to happen after the checkout moves from one commit to another, from the files that changed.
// The project's config lists the steps; they run in the order it gives them.

// A step's `when` (or a note's): a RegExp, a path ("mix.lock" is that file, "migrations/" anything under
// it), a list of those, or a function of the path. Paths are relative to the repo root.
export const matcher = (when) => {
  if (when === undefined || when === null) return () => false;
  const one = (w) => (typeof w === "function" ? w : w instanceof RegExp ? (path) => w.test(path) : w.endsWith("/") ? (path) => path.startsWith(w) : (path) => path === w);
  const list = [].concat(when).map(one);
  return (path) => list.some((test) => test(path));
};

// `run` as a string goes through sh -c; as an array it is the command and its arguments.
export const command = (run) => (Array.isArray(run) ? { cmd: run[0], args: run.slice(1) } : { cmd: "sh", args: ["-c", run] });

// One configured step, ready to run: { name, label, cmd, args, cwd, test(path), waitForPort? }.
export const normaliseStep = (step, i) => {
  if (!step.run) throw new Error(`Step ${step.label ?? step.name ?? i + 1} has no run`);
  const text = [].concat(step.run).join(" ");
  return {
    name: step.name ?? text.split(" ")[0],
    label: step.label ?? text,
    ...command(step.run),
    cwd: step.cwd ?? ".",
    test: matcher(step.when),
    ...(step.waitForPort ? { waitForPort: step.waitForPort } : {}),
  };
};

// The steps for these changed paths, or every step with `all`. A step without `when` only runs with all.
export const planSteps = (steps, changed, { all = false } = {}) =>
  steps.filter((step) => all || changed.some((path) => step.test(path))).map(({ test, ...step }) => step);

// The messages for these changed paths (e.g. "restart OpenDeck to load the plugin").
export const planNotes = (notes, changed) => notes.filter((note) => changed.some((path) => note.test(path))).map((note) => note.message);
