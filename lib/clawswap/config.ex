defmodule Clawswap.Config do
  @moduledoc """
  The project clawswap runs: its clawswap.exs or clawswap.yml (committed, at the repo root or in a project's subfolder),
  with any override configs `clawswap up <name>` layers over it (see `merge/2`), and the per-checkout state in
  .git/clawswap.json (a smee.io channel of its own, when it doesn't use the daemon's shared one, and the
  commit the steps last ran for, so `up` can catch up a checkout that moved while clawswap wasn't watching).
  """

  alias Clawswap.{Git, Plan}

  @file_name "clawswap.exs"
  def file_name, do: @file_name

  # The names a config can have. One folder may hold only one of them.
  @file_names [@file_name, "clawswap.yml", "clawswap.yaml"]
  def file_names, do: @file_names

  @doc "The config as the rest of clawswap uses it, with the defaults filled in. See docs/configuration.html for each field."
  def normalise(config, opts) do
    config = Map.new(config)
    root = Keyword.fetch!(opts, :root)
    file = opts[:file] || @file_name
    overrides = opts[:overrides] || []

    servers =
      for {name, s} <- config[:servers] || [], into: %{} do
        s = Map.new(s)
        s[:command] || raise ArgumentError, "Server #{name} has no command"
        {to_string(name), %{command: s.command, cwd: s[:cwd] || ".", port: s[:port], match: s[:match]}}
      end

    panes =
      for {name, p} <- config[:panes] || [], into: %{} do
        p = Map.new(p || [])
        # No command (or an empty one): a plain shell in the pane's folder.
        {to_string(name), %{command: if(p[:command] in [nil, "", []], do: nil, else: p[:command]), cwd: p[:cwd] || "."}}
      end

    for name <- Map.keys(panes), Map.has_key?(servers, name) or name == "clawswap" do
      raise ArgumentError, "Pane name #{name} is taken"
    end

    name = config[:name] || Path.basename(root)
    # The environment the project was registered from (the shell `clawswap up` ran in): what the steps it
    # runs see, and where CLAWSWAP_* settings are read from. This VM's own, outside the daemon.
    host_env = opts[:env] || System.get_env()
    env = &env(host_env, &1)
    session = env.("CLAWSWAP_SESSION") || config[:session] || name

    %{
      root: root,
      file: file,
      local_file: opts[:local_file] || Path.join([root, ".git", "clawswap.json"]),
      name: name,
      # The project's name in the daemon's URLs (/p/<id>/), from its session, which is unique per project
      # anyway (two sessions can't share a name).
      id: id(session),
      session: session,
      host_env: host_env,
      base: env.("CLAWSWAP_BASE") || config[:base] || opts[:base] || "main",
      # The daemon's port: projects that name the same one (27390 unless they say otherwise) share a daemon.
      port: String.to_integer(env.("CLAWSWAP_PORT") || to_string(config[:port] || 27390)),
      # Pages allowed to call the API from a browser: the servers' own, and any the config adds.
      origins: MapSet.new(server_origins(servers) ++ (config[:origins] || [])),
      # Server and pane order, as written: a map would lose it.
      server_names: for({n, _} <- config[:servers] || [], do: to_string(n)),
      pane_names: for({n, _} <- config[:panes] || [], do: to_string(n)),
      servers: servers,
      panes: panes,
      layout: config[:layout],
      multiplexer: env.("CLAWSWAP_MULTIPLEXER") || config[:multiplexer],
      prepare: (config[:prepare] || []) |> Enum.with_index() |> Enum.map(fn {s, i} -> Plan.normalise_step(s, i) end),
      steps: (config[:steps] || []) |> Enum.with_index() |> Enum.map(fn {s, i} -> Plan.normalise_step(s, i) end),
      notes: for(n <- config[:notes] || [], do: %{message: Map.new(n).message, test: Plan.matcher(Map.new(n)[:when])}),
      # The override configs layered over `file` (`clawswap up <name>`), from the root, in order.
      overrides: overrides,
      # A switch that changes these restarts the watcher, so it runs the new config.
      restart: Plan.matcher([file | overrides] ++ List.wrap(config[:restart_when])),
      # Walkthrough scripts, relative to the config's folder (see Clawswap.Walkthrough).
      walkthroughs: config[:walkthroughs] || "walkthroughs",
      # Browser tests (`clawswap test`), relative to the config's folder (see Clawswap.BrowserTests).
      browser_tests: config[:browser_tests] || "browser_tests",
      short_name: config[:short_name] || (&String.replace_prefix(&1, "claude/", ""))
    }
  end

  @doc "A project's id in the daemon's URLs: its session's name, lower case, with only letters, digits, - and _."
  def id(session) do
    case session |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9_-]+/, "-") |> String.trim("-") do
      "" -> "project"
      id -> id
    end
  end

  @doc """
  The address of one of the project's servers by its name (the first with a port when it's nil), or of
  the project's clawswap page with `:clawswap` (the daemon's /p/<id>), plus `path`. Walkthroughs' and
  browser tests' `url/2`.
  """
  def url(project, server, path) when server in [:clawswap, "clawswap"], do: "http://localhost:#{project.port}/p/#{project.id}#{path}"

  def url(project, server, path) do
    port =
      cond do
        server == nil ->
          Enum.find_value(project.server_names, &project.servers[&1].port) || raise "None of the servers has a port"

        true ->
          (project.servers[to_string(server)] || raise("No server called #{server}")).port || raise "Server #{server} has no port"
      end

    "http://localhost:#{port}#{path}"
  end

  defp env(env, name), do: env[name] |> then(&if(&1 == "", do: nil, else: &1))

  defp server_origins(servers) do
    for {_, %{port: port}} <- servers, port, origin <- ["http://localhost:#{port}", "http://127.0.0.1:#{port}"], do: origin
  end

  @doc """
  Finds the repo from `cwd` and loads its config: the nearest clawswap.exs or clawswap.yml (or .yaml) from
  `cwd` up to the repo's root, so a project in a subfolder (examples/react-embed, say) has its own. A
  folder with more than one is an error. CLAWSWAP_CONFIG names another file, relative to the root.

  CLAWSWAP_OVERRIDES (which `clawswap up <name>...` sets) lists override configs, comma separated, that
  are merged over it in order (see `merge/2`): each a file, from `cwd`, or a name, for the
  clawswap.<name>.exs (or .yml, .yaml) beside the config.
  """
  def load(cwd, host_env \\ System.get_env()) do
    with {:ok, root} <- Git.repo_root(cwd),
         {:ok, file} <- find(cwd, root, host_env),
         {:ok, config} <- read(Path.expand(file, root)),
         {:ok, overrides} <- find_overrides(cwd, root, file, host_env),
         {:ok, config} <- read_overrides(config || [], overrides, root) do
      {:ok,
       normalise(config,
         root: root,
         file: file,
         overrides: overrides,
         base: Git.default_base(root),
         local_file: Git.git_path(root, "clawswap.json"),
         env: host_env
       )}
    end
  end

  @doc "The names CLAWSWAP_OVERRIDES lists."
  def override_names(host_env) do
    (env(host_env, "CLAWSWAP_OVERRIDES") || "") |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  @doc "The names of the override configs beside the config `file` (from `root`): what `clawswap up <name>` takes."
  def override_choices(root, file) do
    dir = Path.dirname(Path.expand(file, root))

    for path <- Path.wildcard(Path.join(dir, "clawswap.*.{exs,yml,yaml}")),
        [_, name, _] <- [Regex.run(~r/^clawswap\.(.+)\.(exs|yml|yaml)$/, Path.basename(path))],
        uniq: true,
        do: name
  end

  # Each override's path from the root.
  defp find_overrides(cwd, root, file, host_env) do
    host_env
    |> override_names()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case find_override(cwd, root, file, name) do
        {:ok, path} -> {:cont, {:ok, acc ++ [Path.relative_to(path, root)]}}
        error -> {:halt, error}
      end
    end)
  end

  defp find_override(cwd, root, file, name) do
    path = Path.expand(name, cwd)
    dir = Path.dirname(Path.expand(file, root))

    if File.regular?(path) do
      {:ok, path}
    else
      case for(ext <- ~w(exs yml yaml), p = Path.join(dir, "clawswap.#{name}.#{ext}"), File.regular?(p), do: p) do
        [path] ->
          {:ok, path}

        [] ->
          choices =
            case override_choices(root, file) do
              [] -> "there are none beside #{file}"
              names -> "there are #{Enum.join(names, ", ")}"
            end

          {:error, "No override config #{name}: no file #{name}, and no clawswap.#{name}.exs or .yml beside #{file} (#{choices})"}

        paths ->
          {:error, "#{Enum.map_join(paths, " and ", &Path.relative_to(&1, root))} are both there: keep one"}
      end
    end
  end

  defp read_overrides(config, overrides, root) do
    Enum.reduce_while(overrides, {:ok, config}, fn file, {:ok, config} ->
      case read(Path.expand(file, root)) do
        {:ok, override} -> {:cont, {:ok, merge(config, override || [])}}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  An override config merged over a config: a keyword list or map in both (the config itself, a server, a
  pane, the servers) is merged key by key, recursively, with keys new to the override after the config's
  own; anything else in the override (a list of steps, a command, a port) replaces the config's. A key
  the override sets to `false` is taken out, so `servers: [api: false]` drops the api server.
  """
  def merge(config, override) do
    if pairs?(override) and (pairs?(config) or config in [nil, []]) do
      config = Enum.to_list(config || [])
      override = Enum.to_list(override)
      key = &to_string(elem(&1, 0))
      over = Map.new(override, &{key.(&1), &1})
      dropped = for {k, false} <- override, into: MapSet.new(), do: to_string(k)

      merged =
        for {k, v} = pair <- config, not MapSet.member?(dropped, key.(pair)) do
          case over[key.(pair)] do
            nil -> pair
            {_, o} -> {k, merge(v, o)}
          end
        end

      known = MapSet.new(config, key)
      merged ++ for({k, v} = pair <- override, v != false, not MapSet.member?(known, key.(pair)), do: {k, v})
    else
      override
    end
  end

  defp pairs?(map) when is_map(map), do: not is_struct(map)
  defp pairs?([_ | _] = list), do: Enum.all?(list, &match?({k, _} when is_atom(k) or is_binary(k), &1))
  defp pairs?(_), do: false

  defp find(cwd, root, host_env) do
    case env(host_env, "CLAWSWAP_CONFIG") do
      nil -> nearest(cwd, root)
      file -> if File.exists?(Path.expand(file, root)), do: {:ok, file}, else: {:error, "No #{file} in #{root}"}
    end
  end

  @doc "A config file's keyword list: a .yml or .yaml is read as YAML, anything else evaluated as Elixir."
  def read(path) do
    if Path.extname(path) in [".yml", ".yaml"] do
      Clawswap.Config.Yaml.read(path)
    else
      {config, _} = Code.eval_file(path)
      {:ok, config}
    end
  end

  # The config's path from the root: in `cwd`'s folder or the closest above it.
  defp nearest(cwd, root) do
    prefix =
      case Git.git(cwd, ["rev-parse", "--show-prefix"]) do
        {:ok, out} -> String.trim(out)
        _ -> ""
      end

    dirs = prefix |> Path.split() |> Enum.scan(&Path.join(&2, &1)) |> Enum.reverse() |> Kernel.++([""])

    Enum.find_value(
      dirs,
      {:error, "No #{Enum.join(@file_names, ", ")} in #{Path.expand(cwd)} or the folders above it in #{root} (clawswap init writes one)"},
      fn dir ->
        case for(name <- @file_names, File.exists?(Path.join([root, dir, name])), do: Path.join(dir, name)) do
          [] -> nil
          [file] -> {:ok, file}
          files -> {:error, "#{Enum.join(files, " and ")} are in the same folder: keep one"}
        end
      end
    )
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

  def drop_local(project, key) do
    File.write!(project.local_file, JSON.encode!(Map.delete(read_local(project), key)) <> "\n")
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
