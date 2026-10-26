// What the watcher knows about branches: the remote's heads (from git, with your usual credentials) and,
// when a GitHub token is available, the open pull requests, for their titles and to leave out branches
// that are merged or abandoned.
import { capture } from "./run.mjs";

const git = (root, ...args) => capture("git", args, { cwd: root });

export const repoRoot = async (cwd = process.cwd()) => (await git(cwd, "rev-parse", "--show-toplevel")).trim();

// Where clawswap keeps its per-checkout state: inside .git, so it is never committed and needs no
// .gitignore entry (worktrees get their own).
export const gitPath = async (root, name) => {
  const path = (await git(root, "rev-parse", "--git-path", name)).trim();
  return path.startsWith("/") ? path : `${root}/${path}`;
};

// origin's default branch (what origin/HEAD points at), else main or master, whichever origin has.
export const defaultBase = async (root) => {
  const head = await git(root, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD").then((o) => o.trim(), () => "");
  if (head) return head.replace(/^origin\//, "");
  for (const name of ["main", "master"]) {
    if (await git(root, "rev-parse", "--verify", "--quiet", `refs/remotes/origin/${name}`).then(() => true, () => false)) return name;
  }
  return "main";
};

export const fetchOrigin = (root) => git(root, "fetch", "--prune", "--quiet", "origin");

// origin's branches, newest commit first: [{ branch, sha, date }].
export const remoteBranches = async (root) => {
  const out = await git(root, "for-each-ref", "--sort=-committerdate", "--format=%(refname:strip=3)%09%(objectname)%09%(committerdate:iso-strict)", "refs/remotes/origin");
  return out
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [branch, sha, date] = line.split("\t");
      return { branch, sha, date };
    })
    .filter((b) => b.branch !== "HEAD");
};

// origin's branches whose commits are all in origin's base branch.
export const mergedBranches = async (root, base) =>
  new Set((await git(root, "branch", "-r", "--merged", `origin/${base}`, "--format=%(refname:strip=3)")).split("\n").filter(Boolean));

export const currentBranch = async (root) => ({
  branch: (await git(root, "rev-parse", "--abbrev-ref", "HEAD")).trim(),
  sha: (await git(root, "rev-parse", "HEAD")).trim(),
});

// Tracked files with changes (untracked ones don't stop a checkout unless they'd be overwritten, and git
// says so then).
export const isDirty = async (root) => (await git(root, "status", "--porcelain", "--untracked-files=no")).trim() !== "";

// owner/name of origin on GitHub, or undefined.
export const githubRepo = async (root) => {
  const url = (await git(root, "remote", "get-url", "origin")).trim();
  return url.match(/github\.com[:/]([^/]+\/[^/]+?)(\.git)?$/)?.[1];
};

// GITHUB_TOKEN, else the gh CLI's token if it's logged in.
export const githubToken = async () => {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN;
  try {
    return (await capture("gh", ["auth", "token"])).trim() || undefined;
  } catch {
    return undefined;
  }
};

// Open pull requests: Map(branch -> { number, title, updatedAt }). Keeps the ETag so an unchanged list is a
// 304, which doesn't count against the rate limit.
export const pullRequestReader = (fetchImpl = fetch) => {
  let etag;
  let last;
  return async (repo, token) => {
    const response = await fetchImpl(`https://api.github.com/repos/${repo}/pulls?state=open&per_page=100&sort=updated&direction=desc`, {
      headers: { Accept: "application/vnd.github+json", Authorization: `Bearer ${token}`, "X-GitHub-Api-Version": "2022-11-28", ...(etag ? { "If-None-Match": etag } : {}) },
    });
    if (response.status === 304 && last) return last;
    if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
    etag = response.headers.get("etag") ?? undefined;
    const pulls = await response.json();
    last = new Map(
      pulls
        .filter((p) => p.head?.repo?.full_name === repo)
        .map((p) => [p.head.ref, { number: p.number, title: p.title, updatedAt: p.updated_at, draft: !!p.draft }]),
    );
    return last;
  };
};

// The list the keys show: the base branch first, then the open PRs' branches by when the PR last changed
// (or, without PR info, every branch by its newest commit). The current branch is always in it.
// `merged`: the branches whose every commit is already in the base branch. `shortName` gives each entry
// the name keys show.
export const branchList = ({ remote, pulls, current, base, merged = new Set(), shortName = (b) => b }) => {
  const byName = new Map(remote.map((b) => [b.branch, b]));
  const entry = (branch) => ({
    branch,
    short: shortName(branch),
    sha: byName.get(branch)?.sha,
    date: byName.get(branch)?.date,
    ...(branch !== base && merged.has(branch) ? { merged: true } : {}),
    ...(pulls?.get(branch) ? { pr: pulls.get(branch) } : {}),
  });
  const rest = pulls
    ? [...pulls.entries()].filter(([b]) => byName.has(b) && b !== base).sort((a, b) => b[1].updatedAt.localeCompare(a[1].updatedAt)).map(([b]) => b)
    : remote.map((b) => b.branch).filter((b) => b !== base);
  const names = [base, ...rest];
  if (current && !names.includes(current) && byName.has(current)) names.splice(1, 0, current);
  return names.filter((b) => byName.has(b)).map(entry);
};
