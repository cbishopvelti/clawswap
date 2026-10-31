defmodule Clawswap.CLI do
  @moduledoc "clawswap's commands. See README.md."

  alias Clawswap.{Config, Git, Multiplexer, Plan, Ports, Smee, Starter, Walkthrough, Watcher}

  @usage """
  Usage: clawswap <command>
    init             Write a starter clawswap.exs in this repo
    up               Start (or attach to) the zellij or tmux session with every server
    status           The branches the keys show, and the last switch
    switch <branch>  Switch branch: stop the servers, check out, update, start them again
    pull             Pull the current branch the same way (nothing happens if it's up to date)
    update [rev]     Run the steps for what changed since they last ran (or since rev), or --all
    smee [url]       Set up the smee.io channel for the GitHub webhook
    walk [name...]   Run walkthroughs in Chrome (default: the ones this branch added); --headless
    browser          Open a dev Chrome that walkthroughs play in, at your app
    layout           Print the layout up opens (zellij's layout, or tmux's commands)
    watch            The watcher, with its page and API (runs in the session's clawswap pane)
  """

  def main(args) do
    case args do
      ["init"] -> init()
      ["up"] -> up()
      ["watch"] -> watch()
      ["status"] -> status()
      ["switch", branch] -> switch(branch)
      ["pull"] -> pull()
      ["update" | rest] -> update(List.first(rest))
      ["smee" | rest] -> smee(List.first(rest))
      ["walk" | rest] -> walk(rest)
      ["browser"] -> browser()
      ["layout"] -> layout()
      [help] when help in ["help", "--help", "-h"] -> IO.write(@usage)
      [] -> IO.write(@usage)
      _ -> fail(@usage)
    end
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
  defp up do
    project = project!()
    mux = Multiplexer.pick(project)

    case mux.check() do
      :ok -> :ok
      {:error, message} -> fail(message)
    end

    command = mux.up(project, fn -> catch_up(project) end)

    case System.get_env("CLAWSWAP_EXEC") do
      nil -> fail("Run this through bin/clawswap, which starts the session: " <> Enum.join(command, " "))
      file -> File.write!(file, Enum.join([project.root | command], "\n") <> "\n")
    end
  end

  defp layout do
    project = project!()
    IO.write(Multiplexer.pick(project).layout(project))
  end

  defp watch do
    project = project!()

    # Hologram's dev server watches its source with inotifywait on Linux, and won't start without it.
    if match?({:unix, :linux}, :os.type()) and !System.find_executable("inotifywait"),
      do: fail("The page needs inotify-tools (sudo apt install inotify-tools)")

    {:ok, _} = Application.ensure_all_started(:clawswap)
    smee = System.get_env("CLAWSWAP_SMEE") || Config.read_local(project)["smee"]
    :ok = Clawswap.Application.start_watcher(project, smee)
    Process.sleep(:infinity)
  end

  # The watcher's port, from the config when there is one (status, switch and pull also work from a
  # checkout without it, with CLAWSWAP_PORT or the default).
  defp api_port do
    case Config.load(repo_dir()) do
      {:ok, project} -> project.port
      _ -> String.to_integer(System.get_env("CLAWSWAP_PORT") || "27390")
    end
  end

  defp api(path, body \\ nil) do
    :inets.start()
    url = String.to_charlist("http://127.0.0.1:#{api_port()}#{path}")

    request =
      if body,
        do: :httpc.request(:post, {url, [], ~c"application/json", JSON.encode!(body)}, [timeout: 120_000], body_format: :binary),
        else: :httpc.request(:get, {url, []}, [timeout: 30_000], body_format: :binary)

    case request do
      {:ok, {{_, status, _}, _, answer}} when status in 200..299 -> JSON.decode!(answer)
      {:ok, {_, _, answer}} -> fail(JSON.decode!(answer)["error"])
      {:error, _} -> fail("The watcher isn't running (start the session with clawswap up)")
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

  defp switch(branch) do
    api("/switch", %{branch: branch})
    IO.puts("Switching to #{branch}; follow it in the clawswap pane")
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
        "--all" -> Plan.steps(project.steps, [], all: true)
        nil -> project |> Config.pending_steps() |> elem(1)
        rev -> Plan.steps(project.steps, elem(Git.changed(project.root, rev, head), 1))
      end

    if steps != [] and not run_steps(project, steps), do: System.halt(1)
    Config.mark_updated(project, head)
    if steps == [], do: IO.puts("Nothing to do")
  end

  # Runs walkthroughs here, one after another: those named, or the ones the branch added or changed. They
  # drive the servers the session runs, so it needs to be up.
  defp walk(args) do
    {flags, names} = Enum.split_with(args, &String.starts_with?(&1, "--"))
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

    opts = if "--headless" in flags, do: [headless: true], else: []

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

  # Opens the dev Chrome (its own profile, kept between runs, with a debugging port) at the first server, so
  # walkthroughs play in a tab of it rather than a window of their own.
  defp browser do
    project = project!()
    cache = System.get_env("XDG_CACHE_HOME") || Path.expand("~/.cache")

    url =
      Enum.find_value(project.server_names, "http://localhost:#{project.port}", &(project.servers[&1].port && "http://localhost:#{project.servers[&1].port}"))

    case Walkthrough.Browser.open_dev_chrome(Path.join(cache, "clawswap/chrome"), url) do
      {:ok, address} -> IO.puts("Dev Chrome on #{address}: walkthroughs play in a tab of it while it's open")
      {:error, message} -> fail(message)
    end
  end

  # Makes a smee.io channel for the GitHub webhook and saves it for this checkout.
  defp smee(url) do
    project = project!()

    channel =
      url ||
        case Smee.new_channel() do
          {:ok, channel} -> channel
          {:error, message} -> fail(message)
        end

    Config.write_local(project, %{"smee" => channel})

    IO.puts("""
    Saved #{channel} in #{project.local_file}.

    Now add the webhook on GitHub (repo Settings > Webhooks > Add webhook):
      Payload URL:  #{channel}
      Content type: application/json
      Events:       Let me select individual events > Branch or tag creation, Branch or tag deletion,
                    Pull requests, Pushes
    Then restart the watcher (Ctrl+C twice in the clawswap pane, then Up and Enter).\
    """)
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
