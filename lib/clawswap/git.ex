defmodule Clawswap.Git do
  @moduledoc """
  What the watcher knows about branches: the remote's heads (from git, with your usual credentials) and,
  when a GitHub token is available, the open pull requests (`Clawswap.GitHub`), for their titles and to
  leave out branches that are merged or abandoned.
  """

  alias Clawswap.Run

  def git(root, args), do: Run.capture("git", args, cwd: root)
  def git!(root, args), do: Run.capture!("git", args, cwd: root)

  def repo_root(cwd) do
    case git(cwd, ["rev-parse", "--show-toplevel"]) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _} -> {:error, "Not in a git checkout"}
    end
  end

  @doc """
  Where clawswap keeps its per-checkout state: inside .git, so it is never committed and needs no
  .gitignore entry (worktrees get their own).
  """
  def git_path(root, name) do
    path = String.trim(git!(root, ["rev-parse", "--git-path", name]))
    Path.expand(path, root)
  end

  @doc "origin's default branch (what origin/HEAD points at), else main or master, whichever origin has."
  def default_base(root) do
    case git(root, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) do
      {:ok, head} when head != "" ->
        head |> String.trim() |> String.replace_prefix("origin/", "")

      _ ->
        Enum.find(["main", "master"], "main", &match?({:ok, _}, git(root, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{&1}"])))
    end
  end

  def fetch_origin(root), do: git(root, ["fetch", "--prune", "--quiet", "origin"])

  @doc "origin's branches, newest commit first: `[%{branch, sha, date}]`."
  def remote_branches(root) do
    root
    |> git!(["for-each-ref", "--sort=-committerdate", "--format=%(refname:strip=3)%09%(objectname)%09%(committerdate:iso-strict)", "refs/remotes/origin"])
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [branch, sha, date] = String.split(line, "\t")
      %{branch: branch, sha: sha, date: date}
    end)
    |> Enum.reject(&(&1.branch == "HEAD"))
  end

  @doc "origin's branches whose commits are all in origin's base branch."
  def merged_branches(root, base) do
    case git(root, ["branch", "-r", "--merged", "origin/#{base}", "--format=%(refname:strip=3)"]) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> MapSet.new()
      {:error, _} -> MapSet.new()
    end
  end

  def current_branch(root) do
    %{branch: String.trim(git!(root, ["rev-parse", "--abbrev-ref", "HEAD"])), sha: head(root)}
  end

  def head(root), do: String.trim(git!(root, ["rev-parse", "HEAD"]))

  @doc """
  Tracked files with changes (untracked ones don't stop a checkout unless they'd be overwritten, and git
  says so then).
  """
  def dirty?(root), do: String.trim(git!(root, ["status", "--porcelain", "--untracked-files=no"])) != ""

  @doc "The checkout's branch on origin, and how many commits it is ahead of the checkout, or nil."
  def upstream(root, branch) do
    with {:ok, sha} <- git(root, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{branch}"]) do
      sha = String.trim(sha)
      %{sha: sha, behind: root |> git!(["rev-list", "--count", "HEAD..#{sha}"]) |> String.trim() |> String.to_integer()}
    else
      _ -> nil
    end
  end

  @doc "The paths that differ between two commits."
  def changed(root, from, to) do
    case git(root, ["diff", "--name-only", from, to]) do
      {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
      error -> error
    end
  end

  @doc "owner/name of origin on GitHub, or nil."
  def github_repo(root) do
    with {:ok, url} <- git(root, ["remote", "get-url", "origin"]),
         [_, repo] <- Regex.run(~r{github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$}, String.trim(url)) do
      repo
    else
      _ -> nil
    end
  end

  @doc """
  The list the keys show: the base branch first, then the others by their newest commit, newest first.
  With PR info that's the open PRs' branches; without it, every branch. The current branch is always in
  it. `remote` comes newest commit first (as `remote_branches/1` gives it). `merged`: the branches whose
  every commit is already in the base branch. `short_name` gives each entry the name keys show.
  """
  def branch_list(opts) do
    remote = Keyword.fetch!(opts, :remote)
    base = Keyword.fetch!(opts, :base)
    pulls = opts[:pulls]
    current = opts[:current]
    merged = opts[:merged] || MapSet.new()
    short_name = opts[:short_name] || (& &1)

    by_name = Map.new(remote, &{&1.branch, &1})

    rest =
      remote
      |> Enum.map(& &1.branch)
      |> Enum.filter(&(&1 != base and (is_nil(pulls) or Map.has_key?(pulls, &1) or &1 == current)))

    [base | rest]
    |> Enum.filter(&Map.has_key?(by_name, &1))
    |> Enum.map(fn branch ->
      %{branch: branch, short: short_name.(branch), sha: by_name[branch].sha, date: by_name[branch].date}
      |> then(&if(branch != base and MapSet.member?(merged, branch), do: Map.put(&1, :merged, true), else: &1))
      |> then(&if(pulls && pulls[branch], do: Map.put(&1, :pr, pulls[branch]), else: &1))
    end)
  end
end
