defmodule Clawswap.Walkthrough do
  @moduledoc """
  Branch walkthroughs: short Elixir scripts, committed in the project's walkthroughs folder, that drive a
  browser through a change so you can watch it instead of clicking through it yourself. Claude writes
  one with a branch; after switching to it you press its ▶ on the watcher's page (or run
  `clawswap walk`), and Chrome opens, slowed down, with a caption for each part.

  This finds a project's walkthroughs and runs one. The commands a script uses are
  `Clawswap.Walkthrough.Script`'s, imported for it; the browser is `Clawswap.Walkthrough.Browser`.
  """

  alias Clawswap.Git
  alias Clawswap.Walkthrough.Browser

  @doc "The walkthroughs folder's path."
  def dir(project), do: Path.expand(project.walkthroughs, Path.dirname(Path.expand(project.file, project.root)))

  @doc """
  The project's walkthroughs, by name (the file's, without .exs): `%{name, path, new}`, with `new` true for
  those the checkout's branch added or changed since it left the base branch, listed first.
  """
  def list(project) do
    dir = dir(project)
    changed = changed_on_branch(project)

    Path.wildcard(Path.join(dir, "*.exs"))
    |> Enum.map(fn path ->
      relative = Path.relative_to(path, project.root)
      %{name: Path.basename(path, ".exs"), path: relative, new: relative in changed}
    end)
    |> Enum.sort_by(&{not &1.new, &1.name})
  end

  defp changed_on_branch(project) do
    base = Enum.find(["origin/#{project.base}", project.base], &match?({:ok, _}, Git.git(project.root, ["rev-parse", "--verify", "--quiet", &1])))

    with base when base != nil <- base, {:ok, out} <- Git.git(project.root, ["diff", "--name-only", "#{base}...HEAD"]) do
      String.split(out, "\n", trim: true)
    else
      _ -> []
    end
  end

  @doc """
  Runs the walkthrough called `name` (or at a path) and closes the browser after it. Returns `:ok`, or
  `{:error, message}` saying which caption and line it failed at, with a screenshot of the moment.

  Options: `headless`, `slow` (ms before each action) as for `Browser.start/1`, `on_step` (called with each
  caption as it's shown), `linger` (ms the browser stays open at the end so you see how it ended; 3000
  when it's visible).
  """
  def run(project, name, opts \\ []) do
    with {:ok, path} <- find(project, name),
         {:ok, browser} <- Browser.start(Keyword.put(opts, :project, project)) do
      try do
        source = File.read!(path)
        # Line 0, so the import doesn't shift the script's line numbers in errors.
        Code.eval_string("import Clawswap.Walkthrough.Script\n" <> source, [], file: path, line: 0)
        Process.sleep(Keyword.get(opts, :linger, if(browser.headless, do: 0, else: 3000)))
        :ok
      rescue
        error -> {:error, failure(error, __STACKTRACE__, path)}
      catch
        kind, reason -> {:error, Exception.format_banner(kind, reason)}
      after
        Browser.stop()
      end
    end
  end

  defp find(project, name) do
    cond do
      String.ends_with?(name, ".exs") and File.exists?(Path.expand(name, project.root)) ->
        {:ok, Path.expand(name, project.root)}

      walk = Enum.find(list(project), &(&1.name == name)) ->
        {:ok, Path.expand(walk.path, project.root)}

      true ->
        {:error, "No walkthrough called #{name} in #{Path.relative_to(dir(project), project.root)}/"}
    end
  end

  # Where it went wrong, for the page and the terminal: the caption showing, the script's line and what
  # failed, and a screenshot.
  defp failure(error, stacktrace, path) do
    line = Enum.find_value(stacktrace, fn {_, _, _, info} -> info[:file] && Path.expand(to_string(info[:file])) == path && info[:line] end)
    caption = Browser.caption()
    shot = Browser.screenshot("walkthrough-failed")

    where = [line && "line #{line}", caption && "at \"#{caption}\""] |> Enum.reject(&is_nil/1) |> Enum.join(", ")
    message = error |> Exception.message() |> String.trim() |> String.split("\n") |> hd()
    shot = if shot, do: " (screenshot: #{shot})", else: ""
    if where == "", do: message <> shot, else: "#{where}: #{message}#{shot}"
  end
end
