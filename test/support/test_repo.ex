defmodule Clawswap.TestRepo do
  @moduledoc "A throwaway origin and clone, with a feature branch that changes the frontend's deps and the schema."

  def git(cwd, args) do
    env = [{"GIT_AUTHOR_NAME", "t"}, {"GIT_AUTHOR_EMAIL", "t@t"}, {"GIT_COMMITTER_NAME", "t"}, {"GIT_COMMITTER_EMAIL", "t@t"}]
    {out, 0} = System.cmd("git", args, cd: cwd, env: env, stderr_to_stdout: true)
    out
  end

  def write(path, text) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  def setup do
    dir = Path.join(System.tmp_dir!(), "clawswap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    work = Path.join(dir, "work")
    git(dir, ["init", "-q", "--bare", "-b", "claude-main", "origin.git"])
    git(dir, ["clone", "-q", "origin.git", "work"])
    write("#{work}/frontend/package.json", "{}\n")
    git(work, ["add", "."])
    git(work, ["commit", "-qm", "base"])
    git(work, ["push", "-q", "origin", "claude-main"])
    git(work, ["checkout", "-qb", "claude/new-thing"])
    write("#{work}/frontend/package.json", ~s({"dependencies":{}}\n))
    write("#{work}/surrealdb/schema.surql", "DEFINE TABLE x;\n")
    git(work, ["add", "."])
    git(work, ["commit", "-qm", "feature"])
    git(work, ["push", "-q", "origin", "claude/new-thing"])
    git(work, ["checkout", "-q", "claude-main"])
    git(work, ["branch", "-qD", "claude/new-thing"])
    %{dir: dir, work: work}
  end

  def bmx_config, do: Path.expand("../../examples/bmx.exs", __DIR__) |> Code.eval_file() |> elem(0)

  def until(check, ms \\ 5000) do
    cond do
      check.() -> :ok
      ms <= 0 -> raise "timed out"
      true -> Process.sleep(20) && until(check, ms - 20)
    end
  end
end
