defmodule Clawswap.Config do
  @moduledoc """
  The project clawswap runs: its clawswap.exs (committed, at the repo root), and the per-checkout state in
  .git/clawswap.json (the smee.io channel, and the commit the steps last ran for, so `up` can catch up a
  checkout that moved while clawswap wasn't watching).
  """

  alias Clawswap.{Git, Plan}

  @file_name "clawswap.exs"
  def file_name, do: @file_name

  @doc "The config as the rest of clawswap uses it, with the defaults filled in. See README.md for each field."
  def normalise(config, opts) do
    config = Map.new(config)
    root = Keyword.fetch!(opts, :root)
    file = opts[:file] || @file_name

    servers =
      for {name, s} <- config[:servers] || [], into: %{} do
        s = Map.new(s)
        s[:command] || raise ArgumentError, "Server #{name} has no command"
        {to_string(name), %{command: s.command, cwd: s[:cwd] || ".", port: s[:port], match: s[:match]}}
      end

    panes =
      for {name, p} <- config[:panes] || [], into: %{} do
        p = Map.new(p)
        {to_string(name), %{command: p[:command], cwd: p[:cwd] || "."}}
      end

    for name <- Map.keys(panes), Map.has_key?(servers, name) or name == "clawswap" do
      raise ArgumentError, "Pane name #{name} is taken"
    end

    name = config[:name] || Path.basename(root)

    %{
      root: root,
      file: file,
      local_file: opts[:local_file] || Path.join([root, ".git", "clawswap.json"]),
      name: name,
      session: env("CLAWSWAP_SESSION") || config[:session] || name,
      base: env("CLAWSWAP_BASE") || config[:base] || opts[:base] || "main",
      port: String.to_integer(env("CLAWSWAP_PORT") || to_string(config[:port] || 8790)),
      # Pages allowed to call the API from a browser: the servers' own, and any the config adds.
      origins: MapSet.new(server_origins(servers) ++ (config[:origins] || [])),
      # Server and pane order, as written: a map would lose it.
      server_names: for({n, _} <- config[:servers] || [], do: to_string(n)),
      pane_names: for({n, _} <- config[:panes] || [], do: to_string(n)),
      servers: servers,
      panes: panes,
      layout: config[:layout],
      prepare: (config[:prepare] || []) |> Enum.with_index() |> Enum.map(fn {s, i} -> Plan.normalise_step(s, i) end),
      steps: (config[:steps] || []) |> Enum.with_index() |> Enum.map(fn {s, i} -> Plan.normalise_step(s, i) end),
      notes: for(n <- config[:notes] || [], do: %{message: Map.new(n).message, test: Plan.matcher(Map.new(n)[:when])}),
      # A switch that changes these restarts the watcher, so it runs the new config.
      restart: Plan.matcher([file | List.wrap(config[:restart_when])]),
      short_name: config[:short_name] || (&String.replace_prefix(&1, "claude/", ""))
    }
  end

  defp env(name), do: System.get_env(name) |> then(&if(&1 == "", do: nil, else: &1))

  defp server_origins(servers) do
    for {_, %{port: port}} <- servers, port, origin <- ["http://localhost:#{port}", "http://127.0.0.1:#{port}"], do: origin
  end

  @doc "Finds the repo from `cwd` and loads its config (CLAWSWAP_CONFIG names another file)."
  def load(cwd) do
    with {:ok, root} <- Git.repo_root(cwd) do
      file = env("CLAWSWAP_CONFIG") || @file_name
      path = Path.expand(file, root)

      if File.exists?(path) do
        {config, _} = Code.eval_file(path)
        {:ok, normalise(config || [], root: root, file: file, base: Git.default_base(root), local_file: Git.git_path(root, "clawswap.json"))}
      else
        {:error, "No #{file} in #{root} (clawswap init writes one)"}
      end
    end
  end

  def read_local(project) do
    with {:ok, text} <- File.read(project.local_file), {:ok, map} <- JSON.decode(text) do
      map
    else
      _ -> %{}
    end
  end

  def write_local(project, changes) do
    File.write!(project.local_file, JSON.encode!(Map.merge(read_local(project), changes)) <> "\n")
  end

  @doc "Remembers that the steps have run for this commit."
  def mark_updated(project, sha), do: write_local(project, %{"updated" => sha})

  @doc """
  The steps HEAD still needs: those for what changed since the last updated commit, or all of them when
  there's none (a first run) or it's no longer known to git. Returns `{head, steps}`.
  """
  def pending_steps(project) do
    head = Git.head(project.root)

    case read_local(project)["updated"] do
      ^head ->
        {head, []}

      nil ->
        {head, Plan.steps(project.steps, [], all: true)}

      last ->
        case Git.changed(project.root, last, head) do
          {:ok, changed} -> {head, Plan.steps(project.steps, changed)}
          {:error, _} -> {head, Plan.steps(project.steps, [], all: true)}
        end
    end
  end
end
