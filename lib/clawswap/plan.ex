defmodule Clawswap.Plan do
  @moduledoc """
  What has to happen after the checkout moves from one commit to another, from the files that changed.
  The project's config lists the steps; they run in the order it gives them.
  """

  @doc """
  A matcher for a step's `when` (or a note's): a Regex, a path ("mix.lock" is that file, "migrations/"
  anything under it), a list of those, or a function of the path. Paths are relative to the repo root.
  """
  def matcher(nil), do: fn _ -> false end

  def matcher(when_) do
    tests = when_ |> List.wrap() |> Enum.map(&one/1)
    fn path -> Enum.any?(tests, & &1.(path)) end
  end

  defp one(fun) when is_function(fun, 1), do: fun
  defp one(%Regex{} = regex), do: &Regex.match?(regex, &1)

  defp one(path) when is_binary(path) do
    if String.ends_with?(path, "/"), do: &String.starts_with?(&1, path), else: &(&1 == path)
  end

  @doc "`run` as a string goes through sh -c; as a list it is the command and its arguments."
  def command([cmd | args]), do: {cmd, args}
  def command(run) when is_binary(run), do: {"sh", ["-c", run]}

  @doc "One configured step, ready to run: `%{name, label, cmd, args, cwd, test, wait_for_port}`."
  def normalise_step(step, i \\ 0) do
    step = Map.new(step)
    run = step[:run] || raise ArgumentError, "Step #{step[:label] || step[:name] || i + 1} has no run"
    text = run |> List.wrap() |> Enum.join(" ")
    {cmd, args} = command(run)

    %{
      name: to_string(step[:name] || text |> String.split(" ") |> hd()),
      label: step[:label] || text,
      cmd: cmd,
      args: args,
      cwd: step[:cwd] || ".",
      test: matcher(step[:when]),
      wait_for_port: step[:wait_for_port]
    }
  end

  @doc "The steps for these changed paths, or every step with `all: true`. A step without `when` only runs with all."
  def steps(steps, changed, opts \\ []) do
    all = opts[:all] || false
    for step <- steps, all or Enum.any?(changed, step.test), do: Map.delete(step, :test)
  end

  @doc "The messages for these changed paths (e.g. \"restart OpenDeck to load the plugin\")."
  def notes(notes, changed), do: for(note <- notes, Enum.any?(changed, note.test), do: note.message)
end
