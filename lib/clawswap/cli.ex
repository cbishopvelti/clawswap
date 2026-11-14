defmodule Clawswap.CLI do
  @moduledoc "clawswap's commands. See README.md."

  alias Clawswap.{BrowserTests, Config, Git, GitHub, Multiplexer, Plan, Ports, SharedSmee, Smee, Starter, Walkthrough, Watcher}

  # Each command: its name, the arguments it takes (as usage shows them), how many it takes at least and at
  # most (:any for no limit), and what it does.
  @commands [
    {"doctor", "", 0, 0, "Check what clawswap needs is installed, and print the fix for what isn't"},
    {"init", "", 0, 0, "Write a starter clawswap.exs in this repo"},
    {"up", "[config...]", 0, :any,
     "Start (or attach to) the zellij or tmux session with every server; with a name (clawswap.<name>.yml) or file, merged over the config"},
    {"status", "", 0, 0, "The branches the keys show, and the last switch"},
    {"switch", "<branch>", 1, 1, "Switch branch (its name, part of it, or its PR number), restarting the servers"},
    {"pull", "", 0, 0, "Pull the current branch the same way (nothing happens if it's up to date)"},
    {"update", "[rev]", 0, 1, "Run the steps for what changed since they last ran (or since rev), or --all"},
    {"smee", "[url]", 0, 1, "Add this repo's GitHub webhook for the shared smee.io channel (up does it); a url or --new: a channel of its own"},
    {"walk", "[name...]", 0, :any, "Run walkthroughs in Chrome (default: the ones this branch added); --headless"},
    {"browser", "", 0, 0, "Open a dev Chrome that walkthroughs play in, at your app"},
    {"test", "[path...]", 0, :any, "Run the browser tests (Wallaby) against the running servers; --watch, --only tag"},
    {"layout", "", 0, 0, "Print the layout up opens (zellij's layout, or tmux's commands)"},
    {"watch", "[config...]", 0, :any, "Run this project in the daemon and follow its log (the session's clawswap pane does)"},
    {"daemon", "", 0, 0, "The daemon that runs every project's watcher, page and API (clawswap up starts it)"},
    {"reload", "", 0, 0, "After changing clawswap: reinstall the OpenDeck plugin, restart OpenDeck, recompile, restart the daemon"},
    {"completion", "install", 1, 2, "Set up Tab completion for your shell (or install bash|zsh|fish); completion bash prints the script"},
    {"help", "", 0, 0, "This list"}
  ]

  # The options each command takes, as OptionParser's strict switches. A command not here takes none, and
  # every command turns down an option it doesn't take (suggesting the closest one), so a typo never runs.
  @switches %{
    "update" => [all: :boolean],
    "smee" => [new: :boolean],
    "walk" => [headless: :boolean],
    "test" => [watch: :boolean, headless: :boolean, only: :keep, exclude: :keep, seed: :integer, max_cases: :integer]
  }

  @usage "Usage: clawswap <command>\n" <>
           Enum.map_join(@commands, fn {name, args, _, _, summary} ->
             "  " <> String.pad_trailing(String.trim("#{name} #{args}"), 20) <> summary <> "\n"
           end)

  @doc "The commands, as `{name, summary}`."
  def commands, do: for({name, _, _, _, summary} <- @commands, do: {name, summary})

  @doc "The options `command` takes, as they're typed (`--max-cases`)."
  def flags(command), do: for({name, _} <- Map.get(@switches, command, []), do: flag(name))

  defp flag(name), do: "--" <> String.replace(to_string(name), "_", "-")

  @doc """
  Reads `args` for `command` with OptionParser: `{:ok, args, opts}`, or `{:error, message}` for an option
  the command doesn't take (with the closest it does), an option's bad value, or the wrong number of arguments.
  """
  def parse(command, args) do
    {_, usage, min, max, _} = List.keyfind(@commands, command, 0)
    {opts, rest, invalid} = OptionParser.parse(args, strict: Map.get(@switches, command, []))

    cond do
      invalid != [] -> {:error, bad_option(command, hd(invalid))}
      length(rest) < min or (max != :any and length(rest) > max) -> {:error, wrong_arguments(command, usage, rest)}
      true -> {:ok, rest, opts}
    end
  end

  defp bad_option(command, {option, value}) do
    flags = flags(command)
    name = option |> String.split("=") |> hd()

    cond do
      name in flags ->
        type = Enum.find_value(@switches[command], fn {key, type} -> flag(key) == name && type end)
        "clawswap: #{command} #{name} takes #{if type == :integer, do: "a number", else: "no value"}, not #{inspect(value)}"

      flags == [] ->
        "clawswap: #{command} takes no options (got #{option}). Usage: #{usage_line(command)}"

      hint = Clawswap.CLI.Forgive.closest(String.trim_leading(name, "-"), Enum.map(flags, &String.trim_leading(&1, "-"))) ->
        "clawswap: #{command} has no option #{name}. Did you mean --#{hint}? (it takes #{Enum.join(flags, ", ")})"

      true ->
        "clawswap: #{command} has no option #{name}; it takes #{Enum.join(flags, ", ")}"
    end
  end

  defp usage_line(command) do
    {_, usage, _, _, _} = List.keyfind(@commands, command, 0)
    "clawswap " <> String.trim("#{command} #{usage}")
  end

  def main(args) do
    case args do
      [] -> IO.write(@usage)
      [help | _] when help in ["help", "--help", "-h"] -> IO.write(@usage)
      [command | rest] -> run(command, rest)
    end
  end

  defp run(command, rest) do
    if List.keymember?(@commands, command, 0) do
      case parse(command, rest) do
        {:ok, args, opts} -> dispatch(command, args, opts)
        {:error, message} -> fail(message)
      end
    else
      unknown(command, rest)
    end
  end

  defp dispatch("doctor", [], _), do: Clawswap.Doctor.main()
  defp dispatch("init", [], _), do: init()
  defp dispatch("up", rest, _), do: with_overrides(rest, &up/0)
  defp dispatch("watch", rest, _), do: with_overrides(rest, &watch/0)
  defp dispatch("daemon", [], _), do: daemon()
  defp dispatch("status", [], _), do: status()
  defp dispatch("switch", [branch], _), do: switch(branch)
  defp dispatch("pull", [], _), do: pull()
  defp dispatch("update", [_], all: true), do: fail("clawswap: update takes a rev or --all, not both")
  defp dispatch("update", rest, opts), do: update(if(opts[:all], do: :all, else: List.first(rest)))
  defp dispatch("smee", rest, opts), do: smee(List.first(rest), opts[:new] == true)
  defp dispatch("walk", names, opts), do: walk(names, opts)
  defp dispatch("browser", [], _), do: browser()
  defp dispatch("test", paths, opts), do: browser_tests(paths, opts)
  defp dispatch("layout", [], _), do: layout()
  defp dispatch("reload", [], _), do: reload()
  defp dispatch("completion", ["install" | shell], _), do: install_completion(List.first(shell))
  defp dispatch("completion", ["refresh"], _), do: refresh_completion()
  defp dispatch("completion", [shell], _), do: completion(shell)
  defp dispatch("completion", args, _), do: fail(wrong_arguments("completion", "install [bash|zsh|fish]", args))

  defp unknown(command, rest) do
    names = Enum.map(@commands, &elem(&1, 0))

    hint =
      case Clawswap.CLI.Forgive.closest(command, names) do
        nil -> "Run clawswap help for the commands."
        name -> "Did you mean clawswap #{Enum.join([name | rest], " ")}? (clawswap help lists the commands)"
      end

    fail("clawswap: there's no command #{inspect(command)}. #{hint}")
  end

  defp wrong_arguments(command, usage, rest) do
    what =
      case usage do
        "" -> "#{command} takes no arguments (got #{Enum.join(rest, " ")})"
        _ when rest == [] -> "#{command} needs #{usage}"
        _ -> "#{command} takes #{usage}, not #{Enum.join(rest, " ")}"
      end

    "clawswap: #{what}. Usage: clawswap #{String.trim("#{command} #{usage}")}"
  end

  defp repo_dir, do: System.get_env("CLAWSWAP_REPO") || File.cwd!()

  defp fail(message) do
    IO.puts(:stderr, String.trim_trailing(message))
    System.halt(1)
  end

  defp project! do
    case Config.load(repo_dir()) do
      {:ok, project} -> project
      {:error, message} -> fail(message)
    end
  end

  # Runs steps one after another in this terminal; true when they all worked.
  defp run_steps(project, steps) do
    run = Watcher.step_runner(project)

    Enum.reduce_while(steps, true, fn step, true ->
      IO.puts(step.label)

      case run.(step) do
        :ok ->
          if step.wait_for_port, do: Ports.wait_for_port(step.wait_for_port)
          {:cont, true}

        {:error, message} ->
          IO.puts(:stderr, "#{step.label} failed: #{message}")
          {:halt, false}
      end
    end)
  end

  # Runs the config's prepare steps (containers and the like), then brings the checkout up to date with
  # HEAD before the servers start, for whatever changed since the steps last ran (a pull or checkout done
  # by hand, or a first run).
  defp catch_up(project) do
    run_steps(project, project.prepare)
    {head, steps} = Config.pending_steps(project)

    if steps != [] do
      IO.puts("Catching up with #{String.slice(head, 0, 7)}: #{Enum.map_join(steps, ", ", & &1.label)}")

      if run_steps(project, steps) do
        Config.mark_updated(project, head)
      else
        IO.puts(:stderr, "Starting the servers anyway; fix that and run clawswap update.")
        Process.sleep(4000)
      end
    end
  end

  # Gets the session ready and leaves the multiplexer's command for bin/clawswap to run, since zellij and
  # tmux need the terminal (CLAWSWAP_EXEC is the file it reads it from).
  # `up` and `watch` name the override configs to layer over the project's config. They go in
  # CLAWSWAP_OVERRIDES, which Config.load reads, here and in the daemon (it gets this environment).
  defp with_overrides([], fun), do: fun.()

  defp with_overrides(names, fun) do
    System.put_env("CLAWSWAP_OVERRIDES", Enum.join(names, ","))
    fun.()
  end

  defp up do
    project = project!()
    if project.overrides != [], do: IO.puts("#{project.file} with #{Enum.join(project.overrides, ", ")} over it")
    mux = Multiplexer.pick(project)

    case mux.check() do
      :ok -> :ok
      {:error, message} -> fail(message)
    end

    # The project's page is up while the session starts (its pane's clawswap watch registers it too).
    ensure_daemon(project)
    register!(project)
    command = mux.up(project, fn -> catch_up(project) end)

    case System.get_env("CLAWSWAP_EXEC") do
      nil -> fail("Run this through bin/clawswap, which starts the session: " <> Enum.join(command, " "))
      file -> File.write!(file, Enum.join([project.root | Multiplexer.with_overrides(project, command)], "\n") <> "\n")
    end
  end

  defp layout do
    project = project!()
    IO.write(Multiplexer.pick(project).layout(project))
  end

  # The session's clawswap pane: runs the project in the daemon (starting the daemon if it isn't running),
  # and shows the project's log. If the daemon goes away, it starts it again and carries on.
  defp watch do
    project = project!()
    :inets.start()
    # The VM shrugs off the SIGHUP a closed pane sends, so it looks for its pane's shell going instead:
    # once the session has ended, it mustn't keep the project (or a daemon) going.
    parent = parent_pid()
    spawn(fn -> exit_with(parent) end)
    watch_loop(project, 0, parent)
  end

  defp parent_pid do
    case System.cmd("ps", ["-o", "ppid=", "-p", System.pid()], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp exit_with(parent) do
    Process.sleep(2000)
    if parent_pid() != parent, do: System.halt(0), else: exit_with(parent)
  end

  defp watch_loop(project, failures, parent) do
    if parent_pid() != parent, do: System.halt(0)
    ensure_daemon(project)

    case register(project) do
      {:ok, info} ->
        IO.puts("\e[36m[clawswap]\e[0m #{project.name}: #{info["url"]} (all projects: http://127.0.0.1:#{project.port}/)")
        follow_log(project)
        IO.puts("\e[36m[clawswap]\e[0m Lost the daemon; starting it again")
        Process.sleep(1000)
        watch_loop(project, 0, parent)

      {:error, message} when failures < 5 ->
        IO.puts(:stderr, "clawswap: #{message}")
        Process.sleep(2000 * (failures + 1))
        watch_loop(project, failures + 1, parent)

      {:error, message} ->
        fail("clawswap: #{message}")
    end
  end

  # Prints the project's log as the daemon sends it, until the daemon closes it.
  defp follow_log(project) do
    url = String.to_charlist("http://127.0.0.1:#{project.port}/p/#{project.id}/log")

    case :httpc.request(:get, {url, []}, [timeout: :infinity], sync: false, stream: :self) do
      {:ok, ref} -> log_loop(ref)
      {:error, _} -> :ok
    end
  end

  defp log_loop(ref) do
    receive do
      {:http, {^ref, :stream_start, _headers}} -> log_loop(ref)
      {:http, {^ref, :stream, text}} -> IO.write(text) && log_loop(ref)
      {:http, {^ref, :stream_end, _headers}} -> :ok
      {:http, {^ref, {{_, status, _}, _, body}}} -> IO.puts(:stderr, "clawswap: the daemon answered #{status}: #{body}")
      {:http, {^ref, {:error, _reason}}} -> :ok
    end
  end

  # The daemon on the project's port: there already, or started now, in the background (it outlives this
  # terminal; its output goes to daemon_log/1).
  defp ensure_daemon(project) do
    case daemon_info(project.port) do
      :daemon ->
        :ok

      :other ->
        fail("Something that isn't clawswap's daemon listens on port #{project.port}; stop it, or give the project another port: in its config")

      :none ->
        log = daemon_log(project.port)
        IO.puts("Starting the clawswap daemon on port #{project.port} (its log: #{log})")
        start_daemon(project.port, log)

        unless wait_for_daemon(project.port, 240),
          do: fail("The clawswap daemon didn't start on port #{project.port}; see #{log}")
    end
  end

  @doc false
  def daemon_log(port) do
    state = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
    Path.join([state, "clawswap", "daemon-#{port}.log"])
  end

  defp start_daemon(port, log) do
    File.mkdir_p!(Path.dirname(log))

    # In a session of its own (setsid, where there is one), ignoring the terminal's signals, so closing
    # this terminal or pressing Ctrl-C in it leaves the daemon running for the other projects.
    script = """
    if command -v setsid >/dev/null 2>&1; then
      (trap '' INT QUIT HUP; exec setsid "$1" daemon) >>"$2" 2>&1 </dev/null &
    else
      (trap '' INT QUIT HUP; exec "$1" daemon) >>"$2" 2>&1 </dev/null &
    fi
    """

    {_, 0} = System.cmd("sh", ["-c", script, "sh", Multiplexer.cli(), log], env: [{"CLAWSWAP_PORT", to_string(port)}], cd: repo_dir())
    :ok
  end

  defp wait_for_daemon(_port, 0), do: false

  defp wait_for_daemon(port, tries) do
    if daemon_info(port) == :daemon do
      true
    else
      Process.sleep(500)
      wait_for_daemon(port, tries - 1)
    end
  end

  # :daemon, :other (something else listens there) or :none.
  defp daemon_info(port) do
    :inets.start()

    case :httpc.request(:get, {String.to_charlist("http://127.0.0.1:#{port}/daemon"), []}, [timeout: 5000, connect_timeout: 2000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        if match?({:ok, %{"clawswap" => "daemon"}}, JSON.decode(body)), do: :daemon, else: :other

      {:ok, _} ->
        :other

      {:error, _} ->
        if Ports.port_open?(port), do: :other, else: :none
    end
  end

  # Runs the project in the daemon, with this shell's environment for its commands.
  defp register(project) do
    body = %{cwd: repo_dir(), env: System.get_env()}
    url = String.to_charlist("http://127.0.0.1:#{project.port}/daemon/projects")

    case :httpc.request(:post, {url, [], ~c"application/json", JSON.encode!(body)}, [timeout: 120_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, answer}} -> {:ok, JSON.decode!(answer)}
      {:ok, {{_, status, _}, _, answer}} -> {:error, with({:ok, %{"error" => e}} <- JSON.decode(answer), do: e, else: (_ -> "the daemon answered #{status}"))}
      {:error, reason} -> {:error, "couldn't reach the daemon: #{inspect(reason)}"}
    end
  end

  defp register!(project) do
    case register(project) do
      {:ok, info} -> IO.puts("#{project.name}'s page: #{info["url"]}")
      {:error, message} -> fail("clawswap: #{message}")
    end
  end

  # The daemon itself (bin/clawswap daemon; clawswap up starts it in the background). It stops on its own
  # after a while with no projects.
  defp daemon do
    # Hologram's dev server watches its source with inotifywait on Linux, and won't start without it.
    if match?({:unix, :linux}, :os.type()) and !System.find_executable("inotifywait"),
      do: fail("The page needs inotify-tools (sudo apt install inotify-tools)")

    port = String.to_integer(System.get_env("CLAWSWAP_PORT") || "27390")
    if Ports.port_open?(port), do: fail("Port #{port} is taken already")
    {:ok, _} = Application.ensure_all_started(:clawswap)
    :ok = Clawswap.Application.start_daemon(port, idle_ms: 60 * 60_000)
    Process.sleep(:infinity)
  end

  # For working on clawswap (or after pulling it): puts the OpenDeck plugin in again and restarts OpenDeck,
  # which only starts plugins when it launches; then recompiles clawswap and restarts the daemon on it. It
  # compiles before stopping the daemon, so a compile error leaves everything running, and the sessions'
  # clawswap panes, which start a lost daemon again within a second or two, find clawswap compiled already.
  defp reload do
    port = daemon_port()
    reload_opendeck()

    IO.puts("Compiling clawswap")
    unless compile_clawswap(), do: fail("clawswap didn't compile; the daemon is left running as it was")

    case stop_daemon(port) do
      :ok -> IO.puts("Stopped the clawswap daemon on port #{port}")
      :none -> IO.puts("No clawswap daemon was running on port #{port}")
    end

    # A session's clawswap pane may have started it again already.
    if wait_for_daemon(port, 6) do
      IO.puts("The clawswap daemon is running again on port #{port} (a session's clawswap pane started it)")
    else
      log = daemon_log(port)
      IO.puts("Starting the clawswap daemon on port #{port} (its log: #{log})")
      start_daemon(port, log)
      unless wait_for_daemon(port, 240), do: fail("The clawswap daemon didn't start on port #{port}; see #{log}")
      IO.puts("The clawswap daemon is running on port #{port}")
    end

    # With the new code, so a command added since completes too.
    System.cmd(Multiplexer.cli(), ["completion", "refresh"], into: IO.stream(), stderr_to_stdout: true)
  end

  defp reload_opendeck do
    if Clawswap.OpenDeck.start_command() == nil and not Clawswap.OpenDeck.running?() do
      IO.puts("No OpenDeck here (set CLAWSWAP_OPENDECK_CMD to the command that starts it); leaving its plugin alone")
    else
      if Clawswap.OpenDeck.stop() == :ok, do: IO.puts("Quit OpenDeck")
      IO.puts("Copied the OpenDeck plugin to #{Clawswap.OpenDeck.install()}")
      log = Path.join(Path.dirname(daemon_log(0)), "opendeck.log")

      case Clawswap.OpenDeck.start(log) do
        {:ok, command} -> IO.puts("Started OpenDeck (#{command}; its output: #{log})")
        :none -> IO.puts("Start OpenDeck again yourself: clawswap doesn't know how here (set CLAWSWAP_OPENDECK_CMD)")
      end
    end
  end

  # Compiles clawswap afresh, with the Elixir this runs on (clawswap's own, not your project's that
  # Clawswap.HostEnv put back on the PATH), and with Hologram's page bundle cleared, since it can otherwise
  # serve the old one.
  defp compile_clawswap do
    tool = Path.expand("../..", __DIR__)
    build = Mix.Project.build_path()
    File.rm_rf!(Path.join(build, "lib/clawswap/priv/static/hologram"))
    File.rm_rf!(Path.join(build, "lib/hologram/priv/tmp"))
    elixir_bin = Path.expand("../../bin", to_string(:code.lib_dir(:elixir)))
    erlang_bin = Path.join(to_string(:code.root_dir()), "bin")
    path = Enum.join([elixir_bin, erlang_bin, System.get_env("PATH", "")], ":")
    env = [{"PATH", path}, {"MIX_ENV", to_string(Mix.env())} | for(v <- ~w(ROOTDIR BINDIR EMU PROGNAME), do: {v, nil})]
    {_, status} = System.cmd("mix", ["compile", "--force"], cd: tool, env: env, into: IO.stream(), stderr_to_stdout: true)
    status == 0
  end

  # Asks the daemon on the port for its OS pid and stops it (killing it if it hasn't gone in 15 seconds).
  defp stop_daemon(port) do
    case :httpc.request(:get, {String.to_charlist("http://127.0.0.1:#{port}/daemon"), []}, [timeout: 5000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case JSON.decode(body) do
          {:ok, %{"clawswap" => "daemon", "pid" => pid}} ->
            System.cmd("kill", [pid], stderr_to_stdout: true)

            unless wait_until_gone(port, 30) do
              System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
              wait_until_gone(port, 10)
            end

            :ok

          _ ->
            fail("Something that isn't clawswap's daemon listens on port #{port}")
        end

      _ ->
        if Ports.port_open?(port), do: fail("Something that isn't clawswap's daemon listens on port #{port}"), else: :none
    end
  end

  defp wait_until_gone(_port, 0), do: false

  defp wait_until_gone(port, tries) do
    if Ports.port_open?(port) do
      Process.sleep(500)
      wait_until_gone(port, tries - 1)
    else
      true
    end
  end

  # The daemon's port: this checkout's project's, or CLAWSWAP_PORT's (27390 without it) outside one.
  defp daemon_port do
    case Config.load(repo_dir()) do
      {:ok, project} -> project.port
      _ -> String.to_integer(System.get_env("CLAWSWAP_PORT") || "27390")
    end
  end

  # Where the API is for this checkout: its project's paths on its daemon (/p/<id>), from the config; or
  # the selected project's on the default daemon (CLAWSWAP_PORT), from a checkout without one.
  defp api_url(path) do
    case Config.load(repo_dir()) do
      {:ok, project} -> "http://127.0.0.1:#{project.port}/p/#{project.id}#{path}"
      _ -> "http://127.0.0.1:#{System.get_env("CLAWSWAP_PORT") || "27390"}#{path}"
    end
  end

  defp api(path, body \\ nil) do
    :inets.start()
    url = String.to_charlist(api_url(path))

    request =
      if body,
        do: :httpc.request(:post, {url, [], ~c"application/json", JSON.encode!(body)}, [timeout: 120_000], body_format: :binary),
        else: :httpc.request(:get, {url, []}, [timeout: 30_000], body_format: :binary)

    case request do
      {:ok, {{_, status, _}, _, answer}} when status in 200..299 -> JSON.decode!(answer)
      {:ok, {_, _, answer}} -> fail(JSON.decode!(answer)["error"])
      {:error, _} -> fail("clawswap isn't running (start the session with clawswap up)")
    end
  end

  # Like api/2, but for a project that may not be running.
  defp tell_watcher(path, body) do
    :inets.start()
    url = String.to_charlist(api_url(path))

    case :httpc.request(:post, {url, [], ~c"application/json", JSON.encode!(body)}, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      {:ok, {{_, 404, _}, _, _}} -> {:error, :not_running}
      {:ok, {{_, status, _}, _, answer}} -> {:error, with({:ok, %{"error" => e}} <- JSON.decode(answer), do: e, else: (_ -> "#{status}"))}
      {:error, _} -> {:error, :not_running}
    end
  end

  defp status do
    s = api("/state")
    current = s["current"]["branch"]
    IO.puts("#{s["project"]}: on #{current}#{if s["dirty"], do: " (uncommitted changes)"}; webhook #{s["webhook"]}")

    s["branches"]
    |> Enum.with_index(1)
    |> Enum.each(fn {b, i} ->
      pr = if b["pr"], do: "  ##{b["pr"]["number"]} #{b["pr"]["title"]}", else: ""
      IO.puts("#{String.pad_leading(to_string(i), 3)}  #{if b["branch"] == current, do: "*", else: " "} #{b["branch"]}#{pr}")
    end)

    if run = s["switch"] do
      IO.puts("Last switch: #{run["target"]}: #{run["phase"]}#{if run["step"], do: " (#{run["step"]})"}#{if run["error"], do: ": #{run["error"]}"}")
    end
  end

  # Takes the branch's name, part of it or its PR number, and says which it picked.
  defp switch(input) do
    branches = api("/state")["branches"]

    branch =
      case Clawswap.CLI.Forgive.branch(input, branches) do
        {:ok, branch} ->
          branch

        {:ambiguous, many} ->
          fail("#{input} could be any of #{Enum.join(many, ", ")}; say which (clawswap status lists them)")

        {:none, nil} ->
          fail("#{input} isn't a listed branch or an open PR's number; clawswap status lists them")

        {:none, close} ->
          fail("#{input} isn't a listed branch. Did you mean clawswap switch #{close}?")
      end

    api("/switch", %{branch: branch})
    IO.puts("Switching to #{branch}#{if branch != input, do: " (from #{input})"}; follow it in the clawswap pane")
  end

  defp completion(shell) do
    case Clawswap.CLI.Completion.script(shell, commands()) do
      nil -> fail("clawswap: no completion for #{shell}; it has #{Enum.join(Clawswap.CLI.Completion.shells(), ", ")}")
      script -> IO.write(script)
    end
  end

  defp install_completion(shell) do
    shells = Clawswap.CLI.Completion.shells()
    shell = shell || Clawswap.CLI.Completion.login_shell()

    cond do
      shell == nil -> fail("clawswap: which shell? Run clawswap completion install #{Enum.join(shells, "|")}")
      shell not in shells -> fail("clawswap: no completion for #{shell}; it has #{Enum.join(shells, ", ")}")
      true -> :ok
    end

    {path, notes} = Clawswap.CLI.Completion.install(shell, commands())
    IO.puts("Saved #{shell} completion to #{path}; clawswap reload keeps it up to date")
    Enum.each(notes, &IO.puts/1)
    IO.puts("Open a new terminal for Tab to complete clawswap's commands")
  end

  # clawswap reload runs this once it has compiled, so the commands are the new ones.
  defp refresh_completion do
    for path <- Clawswap.CLI.Completion.refresh(commands()), do: IO.puts("Updated the completion in #{path}")
  end

  defp pull do
    run = api("/pull", %{})["switch"]
    IO.puts(if run["phase"] == "running", do: "Pulling #{run["target"]}; follow it in the clawswap pane", else: Enum.join(run["notes"], "\n"))
  end

  # Runs the steps by hand: for what changed since they last ran (or since rev), or all of them with --all.
  defp update(arg) do
    project = project!()
    head = Git.head(project.root)

    steps =
      case arg do
        :all -> Plan.steps(project.steps, [], all: true)
        nil -> project |> Config.pending_steps() |> elem(1)
        rev -> Plan.steps(project.steps, elem(Git.changed(project.root, rev, head), 1))
      end

    if steps != [] and not run_steps(project, steps), do: System.halt(1)
    Config.mark_updated(project, head)
    if steps == [], do: IO.puts("Nothing to do")
  end

  # Runs walkthroughs here, one after another: those named, or the ones the branch added or changed. They
  # drive the servers the session runs, so it needs to be up.
  defp walk(names, flags) do
    project = project!()
    list = Walkthrough.list(project)
    folder = Path.relative_to(Walkthrough.dir(project), project.root) <> "/"

    names =
      cond do
        names != [] -> names
        list == [] -> fail("No walkthroughs in #{folder} yet. See README.md's Walkthroughs.")
        Enum.any?(list, & &1.new) -> for w <- list, w.new, do: w.name
        true -> fail("None of the walkthroughs is new on this branch; name one: #{Enum.map_join(list, ", ", & &1.name)}")
      end

    opts = Keyword.take(flags, [:headless])

    failed =
      Enum.reject(names, fn name ->
        IO.puts("Walkthrough #{name}")

        case Walkthrough.run(project, name, opts) do
          :ok ->
            IO.puts("#{name} ran to the end")
            true

          {:error, message} ->
            IO.puts(:stderr, "#{name} failed: #{message}")
            false
        end
      end)

    if failed != [], do: System.halt(1)
  end

  # Runs the project's browser tests (Clawswap.BrowserTests) with ExUnit, headless unless --watch, and exits
  # 1 when one fails. Paths are relative to where you ran it.
  defp browser_tests(names, flags) do
    project = project!()

    files =
      case BrowserTests.files(project, names, repo_dir()) do
        {:ok, files} -> files
        {:error, message} -> fail(message <> ". See README.md's Browser tests.")
      end

    first = Enum.find_value(project.server_names, &project.servers[&1].port)

    if first && not Ports.port_open?(first) do
      IO.puts(:stderr, "Nothing is listening on #{first} yet: the tests drive the servers `clawswap up` runs.")
    end

    headless =
      cond do
        flags[:watch] -> false
        flags[:headless] -> true
        true -> nil
      end

    opts =
      [headless: headless, include: Keyword.get_values(flags, :only), exclude: Keyword.get_values(flags, :exclude)] ++
        Keyword.take(flags, [:seed, :max_cases])

    opts = Enum.reject(opts, fn {_, v} -> is_nil(v) end)

    case BrowserTests.run(project, files, opts) do
      {:ok, 0} -> :ok
      {:ok, _} -> System.halt(1)
      {:error, message} -> fail(message)
    end
  end

  # Opens the dev Chrome (its own profile, kept between runs, with a debugging port) at the first server, so
  # walkthroughs play in a tab of it rather than a window of their own.
  defp browser do
    project = project!()
    cache = System.get_env("XDG_CACHE_HOME") || Path.expand("~/.cache")

    url =
      Enum.find_value(project.server_names, Config.url(project, :clawswap, ""), &(project.servers[&1].port && "http://localhost:#{project.servers[&1].port}"))

    case Walkthrough.Browser.open_dev_chrome(Path.join(cache, "clawswap/chrome"), url) do
      {:ok, address} -> IO.puts("Dev Chrome on #{address}: walkthroughs play in a tab of it while it's open")
      {:error, message} -> fail(message)
    end
  end

  # Without a url: adds the repo's webhook for the daemon's shared channel (making the channel if the
  # daemon hasn't yet), stops using a channel of the checkout's own, and tells a running watcher. The
  # daemon adds the webhook by itself the first time a repo comes in, so this is for trying again (or
  # moving a checkout that had a channel of its own onto the shared one).
  defp smee(nil, false) do
    project = project!()
    old = Config.read_local(project)["smee"]

    channel =
      case SharedSmee.ensure_channel() do
        {:ok, channel} -> channel
        {:error, message} -> fail(message)
      end

    if old, do: Config.drop_local(project, "smee")
    IO.puts("The shared channel is #{channel} (kept in #{SharedSmee.file()}).")

    webhook(project, channel, old)

    case tell_watcher("/smee", %{shared: true}) do
      :ok -> IO.puts("The watcher is following it now.")
      {:error, :not_running} -> IO.puts("The watcher follows it when it starts (clawswap up).")
      {:error, message} -> IO.puts("The watcher didn't take it (#{message}); it follows it when it next starts.")
    end
  end

  # A channel of the checkout's own (given, or new with --new): saved for this checkout, the webhook added
  # on GitHub when the token may, and a running watcher told to follow it.
  defp smee(url, new?) do
    cond do
      url && new? -> fail("clawswap: smee takes a url or --new, not both")
      url == "new" -> fail("clawswap: smee new is now clawswap smee --new (a url is the channel to use)")
      url && not String.match?(url, ~r{^https?://}) -> fail("clawswap: smee takes a channel's url (https://smee.io/...), not #{inspect(url)}")
      true -> :ok
    end

    project = project!()
    old = Config.read_local(project)["smee"] || SharedSmee.channel()

    channel =
      if new? do
        case Smee.new_channel() do
          {:ok, channel} -> channel
          {:error, message} -> fail(message)
        end
      else
        url
      end

    Config.write_local(project, %{"smee" => channel})
    IO.puts("Saved #{channel} in #{project.local_file}.")

    webhook(project, channel, old)

    case tell_watcher("/smee", %{url: channel}) do
      :ok -> IO.puts("The watcher is following it now.")
      {:error, :not_running} -> IO.puts("The watcher follows it when it starts (clawswap up).")
      {:error, message} -> IO.puts("The watcher didn't take it (#{message}); it follows it when it next starts.")
    end
  end

  defp webhook(project, channel, old) do
    repo = Git.github_repo(project.root)
    token = GitHub.token()

    result =
      cond do
        repo == nil -> {:error, "origin isn't a GitHub repo"}
        token == nil -> {:error, "no GitHub token (log in with gh auth login, or set GITHUB_TOKEN)"}
        true -> GitHub.ensure_hook(repo, token, channel, old, &yes?("Remove #{repo}'s webhook for the old channel, #{&1}?"))
      end

    case result do
      {:ok, outcome, removed} ->
        IO.puts(if outcome == :created, do: "Added the webhook on #{repo}.", else: "#{repo} already has the webhook.")
        if removed, do: IO.puts("Removed the old channel's webhook.")

      {:error, message} ->
        IO.puts("""
        Couldn't add the webhook on GitHub: #{message}.
        If you added it by hand, check its Payload URL is the one below; the watcher listens all the same,
        and shows the webhook on once a delivery comes in. Otherwise add it (repo Settings > Webhooks > Add webhook):
          Payload URL:  #{channel}
          Content type: application/json
          Events:       Let me select individual events > Branch or tag creation, Branch or tag deletion,
                        Pull requests, Pushes\
        """)
    end
  end

  defp yes?(question) do
    case IO.gets("#{question} [Y/n] ") do
      answer when is_binary(answer) -> String.trim(answer) in ["", "y", "Y", "yes"]
      _ -> false
    end
  end

  defp init do
    root =
      case Git.repo_root(repo_dir()),
        do: (
          {:ok, root} -> root
          {:error, message} -> fail(message)
        )

    path = Path.join(root, Config.file_name())

    for name <- Config.file_names(), File.exists?(Path.join(root, name)) do
      fail("#{Path.join(root, name)} already exists")
    end

    File.write!(path, Starter.config(root))

    found =
      case Starter.detect(root) do
        :phoenix -> "a Phoenix app, so it runs mix phx.server"
        :mix -> "a Mix project; add the server it runs"
        {:node, manager, _} -> "a Node project, so it runs #{manager} run dev"
        :unknown -> "no project it knows; add your servers"
      end

    IO.puts("Wrote #{path} (found #{found}). Check the servers and steps, then run clawswap up.")
  end
end
