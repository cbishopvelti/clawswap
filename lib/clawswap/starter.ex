defmodule Clawswap.Starter do
  @moduledoc """
  The `clawswap.exs` that `clawswap init` writes, filled in from what's at the repo's root: a Phoenix app
  (`mix.exs` with `:phoenix`), another Mix project, a Node project (`package.json` with a `dev` script),
  or, when it can't tell, no servers and a commented-out example.
  """

  @doc "The kind of project at `root`: `:phoenix`, `:mix`, `{:node, manager, port}` or `:unknown`."
  def detect(root) do
    mix = read(root, "mix.exs")
    package = with text when is_binary(text) <- read(root, "package.json"), {:ok, map} <- JSON.decode(text), do: map, else: (_ -> nil)

    cond do
      mix && mix =~ ~r/\{\s*:phoenix\s*,/ -> :phoenix
      mix -> :mix
      is_map(package) and is_map_key(package["scripts"] || %{}, "dev") -> {:node, node_manager(root), node_port(package)}
      true -> :unknown
    end
  end

  @doc "The starter config's text for `root`."
  def config(root) do
    {servers, steps} = parts(detect(root), root)

    """
    # clawswap's settings for this repo. See https://github.com/cbishopvelti/clawswap#configuration
    [
      # base: "main",            # the branch listed first (default: origin's default branch)
      # port: 27390,              # the watcher's page and API; give each project its own to run several
      # multiplexer: :tmux,      # or :zellij (default: the one you're in, else zellij if installed, else tmux)

      # The servers a switch stops and starts again, each in its own pane.
    #{servers},

      # Other panes in the session, left running across switches.
      # panes: [logs: [command: "docker compose logs -f"]],

      # Runs before `clawswap up` starts a new session.
      # prepare: [[label: "Starting Postgres", run: "docker compose up -d postgres", wait_for_port: 5432]],

      # What a switch runs when these files changed, in this order. "dir/" matches anything under it.
    #{steps}

      # Said after a switch that changed these files.
      # notes: [[when: "plugin/", message: "The plugin changed: reload it"]]
    ]
    """
  end

  defp parts(:phoenix, root) do
    migrate =
      if File.dir?(Path.join(root, "priv/repo/migrations")),
        do: [~s([label: "mix ecto.migrate", when: "priv/repo/migrations/", run: "mix ecto.migrate"])],
        else: []

    {servers([~s(web: [command: "mix phx.server", cwd: ".", port: 4000])]), steps([deps_get() | migrate])}
  end

  defp parts(:mix, _root) do
    {servers([], ~s(# web: [command: "mix run --no-halt", cwd: ".", port: 4000])), steps([deps_get()])}
  end

  defp parts({:node, manager, port}, _root) do
    port = if port, do: ", port: #{port}", else: ""
    lock = Map.fetch!(%{"npm" => "package-lock.json", "yarn" => "yarn.lock", "pnpm" => "pnpm-lock.yaml"}, manager)

    {servers([~s(web: [command: "#{manager} run dev", cwd: ".") <> port <> "]"]),
     steps([~s([label: "#{manager} install", when: ["package.json", "#{lock}"], run: "#{manager} install"])])}
  end

  defp parts(:unknown, _root) do
    {servers([], ~s(# web: [command: "mix phx.server", cwd: ".", port: 4000])),
     steps([], ~s(# [label: "mix deps.get", when: ["mix.exs", "mix.lock"], run: "mix deps.get"]))}
  end

  defp deps_get, do: ~s([label: "mix deps.get", when: ["mix.exs", "mix.lock"], run: "mix deps.get"])

  defp servers(lines, example \\ nil), do: list("servers", lines, example) |> String.trim_trailing()
  defp steps(lines, example \\ nil), do: list("steps", lines, example)

  # `  key: [...]`, one entry a line, or an empty list with a commented-out entry to start from.
  defp list(key, [], example), do: "  #{key}: [\n    #{example}\n  ]"
  defp list(key, lines, _), do: "  #{key}: [\n" <> Enum.map_join(lines, ",\n", &("    " <> &1)) <> "\n  ]"

  defp node_manager(root) do
    cond do
      File.exists?(Path.join(root, "pnpm-lock.yaml")) -> "pnpm"
      File.exists?(Path.join(root, "yarn.lock")) -> "yarn"
      true -> "npm"
    end
  end

  # Vite's and Next's default ports; others are left for you to fill in.
  defp node_port(package) do
    deps = Map.merge(package["dependencies"] || %{}, package["devDependencies"] || %{})

    cond do
      is_map_key(deps, "vite") -> 5173
      is_map_key(deps, "next") -> 3000
      true -> nil
    end
  end

  defp read(root, name) do
    case File.read(Path.join(root, name)) do
      {:ok, text} -> text
      _ -> nil
    end
  end
end
