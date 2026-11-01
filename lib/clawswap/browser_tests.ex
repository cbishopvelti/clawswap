defmodule Clawswap.BrowserTests do
  @moduledoc """
  A project's browser tests: ExUnit files (`*_test.exs`) in its browser_tests folder that drive Chrome
  through Wallaby against the servers the session runs, so any project clawswap runs (a Phoenix app, a
  Vite one) gets a suite without adding anything to its own build. `clawswap test` runs them.

  The modules `use Clawswap.Feature`. A `test_helper.exs` in the folder, if there is one, runs first.
  Chrome is set up as for walkthroughs (`Clawswap.Walkthrough.Browser.setup_tests/1`): headless unless
  asked otherwise, each session a window of its own.
  """

  alias Clawswap.Walkthrough.Browser

  @doc "The browser tests folder's path."
  def dir(project), do: Path.expand(project.browser_tests, Path.dirname(Path.expand(project.file, project.root)))

  @doc """
  The test files to run: those named (files or folders, relative to `cwd`), or all of the folder's.
  `{:ok, paths}` or `{:error, message}`.
  """
  def files(project, names, cwd \\ nil) do
    cwd = cwd || project.root
    # The folder may not be there yet: that's the same as an empty one.
    paths = if names == [], do: Enum.filter([dir(project)], &File.dir?/1), else: Enum.map(names, &Path.expand(&1, cwd))

    case Enum.reject(paths, &File.exists?/1) do
      [] ->
        files =
          paths
          |> Enum.flat_map(fn path -> if File.dir?(path), do: Path.wildcard(Path.join(path, "**/*_test.exs")), else: [path] end)
          |> Enum.uniq()
          |> Enum.sort()

        if files == [],
          do: {:error, "No browser tests (*_test.exs) in #{Path.relative_to(dir(project), project.root)}/ yet"},
          else: {:ok, files}

      [missing | _] ->
        {:error, "No such file or folder: #{Path.relative_to(missing, cwd)}"}
    end
  end

  @doc """
  Runs the files with ExUnit. Options: `headless`, `include` and `exclude` (tags, as `mix test`'s
  `--only` and `--exclude` take them), `seed`, `max_cases`. Returns `{:ok, failures}` or `{:error, message}`.
  """
  def run(project, files, opts \\ []) do
    with :ok <- Browser.setup_tests(Keyword.take(opts, [:headless])) do
      Application.put_env(:clawswap, :browser_tests_project, project)
      include = Enum.map(opts[:include] || [], &tag/1)
      exclude = Enum.map(opts[:exclude] || [], &tag/1)

      ExUnit.start(
        [autorun: false, include: include, exclude: if(include != [], do: [:test | exclude], else: exclude)] ++
          Keyword.take(opts, [:seed, :max_cases])
      )

      helper = Path.join(dir(project), "test_helper.exs")
      if File.exists?(helper), do: Code.require_file(helper)

      case Kernel.ParallelCompiler.require(files, return_diagnostics: true) do
        {:ok, _, _} -> {:ok, ExUnit.run().failures}
        {:error, errors, _} -> {:error, "The tests didn't compile: #{Enum.map_join(errors, "\n", &describe/1)}"}
      end
    end
  end

  # "wip" -> :wip, "browser:chrome" -> {:browser, "chrome"}
  defp tag(tag) do
    case String.split(tag, ":", parts: 2) do
      [key, value] -> {String.to_atom(key), value}
      [key] -> String.to_atom(key)
    end
  end

  defp describe(%{file: file, position: position, message: message}), do: "#{file}:#{inspect(position)}: #{message}"
  defp describe(other), do: inspect(other)
end
