defmodule Clawswap.Integration do
  @moduledoc """
  For clawswap's browser tests (test/integration, `mix test.integration`): a copy of examples/react-embed
  in a repo of its own, with a local origin and a few branches, and `clawswap up` run for it in a tmux
  server of the tests' own, as you'd run it yourself. The tests then drive Chrome with the walkthrough
  commands (`Clawswap.Walkthrough.Script`).

  The branches: `main`; `claude/merged-fix`, merged into it; and `claude/new-heading`, which changes the
  app's heading and adds a walkthrough that checks it.
  """

  import Clawswap.TestRepo, only: [git: 2, write: 2]

  alias Clawswap.Walkthrough.Browser

  @tool Path.expand("../..", __DIR__)
  @example Path.join(@tool, "examples/react-embed")
  # The tests' own tmux server, so they neither see nor touch yours.
  @socket "clawswap-tests"
  @ports [8790, 5173]

  def heading, do: "Hello from the new-heading branch"

  @doc "Compiles clawswap as bin/clawswap runs it (MIX_ENV=dev), once, before the first `up`."
  def compile! do
    {out, code} = System.cmd("mix", ["compile"], cd: @tool, env: [{"MIX_ENV", "dev"}], stderr_to_stdout: true)
    if code != 0, do: raise("mix compile failed:\n" <> out)
    :ok
  end

  @doc "The example's repo, with its origin and branches, and node_modules in place."
  def project! do
    dir = Path.join(System.tmp_dir!(), "clawswap-it-#{System.unique_integer([:positive])}")
    work = Path.join(dir, "react-embed")
    File.mkdir_p!(dir)
    git(dir, ["init", "-q", "--bare", "-b", "main", "origin.git"])
    git(dir, ["clone", "-q", "origin.git", "react-embed"])

    for name <- File.ls!(@example), name != "node_modules", do: File.cp_r!(Path.join(@example, name), Path.join(work, name))
    git(work, ["add", "."])
    git(work, ["commit", "-qm", "react-embed"])

    git(work, ["checkout", "-qb", "claude/merged-fix"])
    write("#{work}/NOTES.md", "A fix that's been merged.\n")
    git(work, ["add", "."])
    git(work, ["commit", "-qm", "Merged fix"])
    git(work, ["checkout", "-q", "main"])
    git(work, ["merge", "-q", "--ff-only", "claude/merged-fix"])

    git(work, ["checkout", "-qb", "claude/new-heading"])
    app = Path.join(work, "src/App.jsx")
    File.write!(app, String.replace(File.read!(app), "Your app goes here", heading()))

    write("#{work}/walkthroughs/new-heading.exs", """
    say "This branch changes the app's heading"
    visit url(:web)
    see "#{heading()}"
    """)

    git(work, ["add", "."])
    git(work, ["commit", "-qm", "New heading"])
    git(work, ["push", "-q", "origin", "main", "claude/merged-fix", "claude/new-heading"])
    git(work, ["checkout", "-q", "main"])
    git(work, ["branch", "-qD", "claude/new-heading", "claude/merged-fix"])

    File.cp_r!(node_modules!(), Path.join(work, "node_modules"))
    %{dir: dir, work: work, session: "clawswap-it-#{System.unique_integer([:positive])}"}
  end

  # npm install once per package-lock.json, shared by the tests' copies.
  defp node_modules! do
    lock = File.read!(Path.join(@example, "package-lock.json"))
    cache = Path.join(System.tmp_dir!(), "clawswap-it-npm-#{:erlang.phash2(lock)}")

    unless File.exists?(Path.join(cache, "node_modules/.bin/vite")) do
      File.mkdir_p!(cache)
      for f <- ["package.json", "package-lock.json"], do: File.cp!(Path.join(@example, f), Path.join(cache, f))
      {out, code} = System.cmd("npm", ["ci", "--no-audit", "--no-fund"], cd: cache, stderr_to_stdout: true)
      if code != 0, do: raise("npm ci failed:\n" <> out)
    end

    Path.join(cache, "node_modules")
  end

  @doc """
  Runs `clawswap up` for the project in `multiplexer` (:zellij or :tmux), inside a pane of the tests' tmux
  server (zellij needs a terminal), and waits until the watcher and the app answer. Attach to watch the
  panes: `tmux -L clawswap-tests attach`.
  """
  def up!(project, multiplexer) do
    free_ports()

    env = [
      # bin/clawswap runs clawswap in dev, as for you, not in the tests' env.
      {"MIX_ENV", nil},
      {"TMUX", nil},
      {"ZELLIJ", nil},
      {"CLAWSWAP_MULTIPLEXER", to_string(multiplexer)},
      {"CLAWSWAP_SESSION", project.session},
      # ▶ on the page runs a walkthrough in the watcher: headless too, unless you're watching.
      {"CLAWSWAP_HEADLESS", System.get_env("CLAWSWAP_HEADLESS") || "1"},
      # Nor in a dev Chrome you may have open.
      {"CLAWSWAP_CHROME_DEBUGGER", "off"}
    ]

    command = "#{Path.join(@tool, "bin/clawswap")} up"
    tmux!(["new-session", "-d", "-s", "up-" <> project.session, "-x", "200", "-y", "50", "-c", project.work, command], env)

    IO.puts("[integration] #{multiplexer} session #{project.session}: tmux -L #{@socket} attach")
    wait_for(fn -> match?({:ok, %{"current" => %{"branch" => "main"}}}, state()) end, 180_000, "the watcher on 8790")
    wait_for(fn -> http_ok?("http://localhost:5173/") end, 120_000, "the app on 5173")
    Map.put(project, :multiplexer, multiplexer)
  end

  @doc "Ends the sessions, and whatever still holds the ports."
  def down!(project) do
    if project[:multiplexer] == :zellij do
      System.cmd("zellij", ["kill-session", project.session], stderr_to_stdout: true)
      System.cmd("zellij", ["delete-session", "--force", project.session], stderr_to_stdout: true)
    end

    System.cmd("tmux", ["-L", @socket, "kill-server"], stderr_to_stdout: true)
    free_ports()
    File.rm_rf!(project.dir)
    :ok
  end

  @doc "Runs bin/clawswap in the project, as you would: `{output, exit status}`."
  def clawswap(project, args, env \\ []) do
    System.cmd(Path.join(@tool, "bin/clawswap"), args, cd: project.work, env: [{"MIX_ENV", nil} | env], stderr_to_stdout: true)
  end

  defp free_ports, do: Enum.each(@ports, &Clawswap.Ports.free_port(&1, fn _ -> :ok end))

  defp tmux!(args, env) do
    {out, code} = System.cmd("tmux", ["-L", @socket, "-f", "/dev/null" | args], env: env, stderr_to_stdout: true)
    if code != 0, do: raise("tmux #{Enum.join(args, " ")}: #{out}")
    out
  end

  @doc "Opens Chrome for the test, headless unless CLAWSWAP_HEADLESS=0, and closes it after."
  def browser!(project) do
    {:ok, config} = Clawswap.Config.load(project.work)
    {:ok, browser} = Browser.start(headless: true, dev_chrome: false, project: config)
    ExUnit.Callbacks.on_exit(fn -> Browser.stop(browser.session) end)
    browser
  end

  @doc "The watcher's /state."
  def state do
    case request(:get, "/state") do
      {:ok, 200, body} -> {:ok, JSON.decode!(body)}
      other -> {:error, other}
    end
  end

  @doc "Posts to the watcher's API, as the keys do."
  def post!(path, body) do
    {:ok, status, answer} = request(:post, path, JSON.encode!(body))
    {status, JSON.decode!(answer)}
  end

  @doc "Waits until the watcher is on `branch`, with its switch done."
  def wait_for_branch(branch, ms \\ 120_000) do
    wait_for(
      fn ->
        match?({:ok, %{"current" => %{"branch" => ^branch}, "switch" => %{"phase" => "done"}}}, state())
      end,
      ms,
      "the switch to #{branch}"
    )
  end

  defp request(method, path, body \\ nil) do
    :inets.start()
    url = ~c"http://127.0.0.1:8790" ++ String.to_charlist(path)

    request =
      if method == :post,
        do: :httpc.request(:post, {url, [], ~c"application/json", body}, [timeout: 30_000], body_format: :binary),
        else: :httpc.request(:get, {url, []}, [timeout: 30_000], body_format: :binary)

    case request do
      {:ok, {{_, status, _}, _, answer}} -> {:ok, status, answer}
      error -> error
    end
  end

  defp http_ok?(url) do
    :inets.start()
    match?({:ok, {{_, 200, _}, _, _}}, :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 5000], []))
  end

  def wait_for(check, ms, what) do
    cond do
      check.() -> :ok
      ms <= 0 -> raise "Timed out waiting for #{what}"
      true -> Process.sleep(250) && wait_for(check, ms - 250, what)
    end
  end
end
