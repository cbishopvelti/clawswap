defmodule Clawswap.Walkthrough.Debugger do
  @moduledoc """
  The debug panel's Chrome (`ClawswapWeb.DebugPanel`, on the right of every clawswap page): one browser that stays open between
  commands, so you can drive it by hand with the walkthrough commands (`visit`, `click`, `see`, `js`...),
  step through a walkthrough a caption at a time, and look around when one stops.

  The browser belongs to a process of its own, the driver, as `Clawswap.Walkthrough.Browser` keeps it in
  the process that started it. This server hands the driver jobs and keeps what the page shows: the log,
  the open tabs and a screenshot after each job (`screenshot/1`).

  A walkthrough run here keeps the browser open when it ends or fails. Run with `step`, it pauses at each
  caption (`say`) until Step or Continue; at a pause, commands run in the same browser, at that point in
  the script. Pause stops a running one at its next caption, and Stop ends it there.

  A command is one call of a walkthrough command, written as in a script (`click "Ping"`,
  `see css(".log", text: "pong")`, `visit url(:relay_a)`). It isn't evaluated as Elixir: only those
  commands, with literal arguments and the query helpers, are run (`command/1`), so the page can't run
  code on this machine. JavaScript runs in the browser with `js "return document.title"`.
  """

  use GenServer

  alias Clawswap.Walkthrough
  alias Clawswap.Walkthrough.{Browser, Script}
  alias Wallaby.WebdriverClient

  @log_max 300

  # The commands the page may run, by name and how many arguments they take.
  @commands %{
    visit: [1],
    click: [1, 2],
    fill_in: [2],
    choose: [2, 3],
    press: [1],
    see: [1, 2],
    refute_see: [1, 2],
    js: [1, 2],
    say: [1],
    pause: [0, 1],
    screenshot: [0],
    url: [0, 1, 2],
    css: [1, 2],
    xpath: [1, 2],
    button: [1, 2],
    link: [1, 2],
    text_field: [1, 2],
    select: [1, 2],
    option: [1, 2]
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "What the page shows (see `init/1`'s view)."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc "The last screenshot, a PNG, or nil."
  def screenshot(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :screenshot)
  end

  @doc "Opens Chrome. Options: `headless` (default: when there's no display)."
  def open(opts \\ []) when is_list(opts), do: open(__MODULE__, opts)
  def open(server, opts), do: GenServer.call(server, {:open, opts})

  @doc "Closes Chrome, stopping a walkthrough that's running."
  def close(server \\ __MODULE__), do: GenServer.call(server, :close)

  @doc "Runs a command (see the moduledoc) in the browser."
  def run(server \\ __MODULE__, code), do: GenServer.call(server, {:run, code})

  @doc "Runs the walkthrough called `name`; `step: true` pauses at its first caption."
  def walk(name, opts \\ []) when is_binary(name), do: walk(__MODULE__, name, opts)
  def walk(server, name, opts), do: GenServer.call(server, {:walk, name, opts})

  @doc "At a pause: `:step` to the next caption, `:continue` to the end, `:stop` here."
  def resume(server \\ __MODULE__, how) when how in [:step, :continue, :stop], do: GenServer.call(server, {:resume, how})

  @doc "Pauses a running walkthrough at its next caption."
  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause)

  @doc "Switches to a tab (its window handle), opens a new one (`:new`) or closes the current one (`:close`)."
  def tab(server \\ __MODULE__, which), do: GenServer.call(server, {:tab, which})

  @doc "Takes a fresh screenshot and looks at the tabs again."
  def refresh(server \\ __MODULE__), do: tab(server, :none)

  @doc """
  Parses a command: `{:ok, {name, args}}`, with the arguments' queries and `url/2`s worked out when it
  runs, or `{:error, message}`. Only the commands above, with strings, numbers, atoms, lists, keyword
  lists and nested query or url calls as arguments.
  """
  def command(code) do
    with {:ok, quoted} <- Code.string_to_quoted(code, existing_atoms_only: true),
         {:ok, call} <- call(quoted) do
      {:ok, call}
    else
      {:error, {_, "unsafe atom" <> _, _}} -> {:error, not_a_command()}
      {:error, {_, message, token}} when is_binary(message) -> {:error, "Couldn't read that: #{message}#{token}"}
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Not a command"}
    end
  rescue
    _ -> {:error, not_a_command()}
  end

  defp not_a_command, do: "Not a command: the commands are #{Enum.join(Enum.sort(Map.keys(@commands)), ", ")}"

  defp call({name, _, args}) when is_atom(name) and is_list(args) do
    with arities when is_list(arities) <- Map.get(@commands, name, {:error, not_a_command()}),
         true <- length(args) in arities || {:error, "#{name} takes #{Enum.join(arities, " or ")} arguments"},
         {:ok, args} <- args(args) do
      {:ok, {:call, name, args}}
    end
  end

  # A module's function, as in `File.rm_rf!("/tmp/x")`. Without this it would say "Not a command" only
  # when the function's name isn't an atom yet (the parse refuses it), and "Write one command" otherwise.
  defp call({{:., _, [_, name]}, _, args}) when is_atom(name) and is_list(args), do: {:error, not_a_command()}

  # A bare name, as in `pause` or `screenshot`.
  defp call({name, _, context}) when is_atom(name) and is_atom(context), do: call({name, [], []})
  defp call(_), do: {:error, "Write one command, as in a walkthrough: click \"Ping\""}

  defp args(args) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      case arg(arg) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp arg(value) when is_binary(value) or is_number(value) or is_atom(value), do: {:ok, value}
  defp arg(list) when is_list(list), do: args(list)
  defp arg({key, value}) when is_atom(key), do: with({:ok, value} <- arg(value), do: {:ok, {key, value}})
  defp arg({:-, _, [n]}) when is_number(n), do: {:ok, -n}
  defp arg({name, _, args} = quoted) when name in [:url, :css, :xpath, :button, :link, :text_field, :select, :option] and is_list(args), do: call(quoted)
  defp arg(other), do: {:error, "Arguments are strings, numbers, atoms, lists or queries, not #{Macro.to_string(other)}"}

  defp perform_call({:call, name, args}), do: apply(Script, name, Enum.map(args, &resolve/1))

  defp resolve({:call, _, _} = call), do: perform_call(call)
  defp resolve(list) when is_list(list), do: Enum.map(list, &resolve/1)
  defp resolve({key, value}), do: {key, resolve(value)}
  defp resolve(value), do: value

  @impl true
  def init(opts) do
    state = %{
      project: opts[:project],
      on_change: opts[:on_change] || fn _ -> :ok end,
      driver: nil,
      monitor: nil,
      session: nil,
      png: nil,
      next: 1,
      jobs: %{},
      view: %{
        # "closed", "opening" or "open"
        browser: "closed",
        headless: false,
        # What the driver is doing (a command, opening), or nil.
        busy: nil,
        # The walkthrough run here: %{name, phase: "running" | "paused" | "passed" | "failed" | "stopped", step, error}.
        walk: nil,
        # %{n, kind: "command" | "result" | "error" | "step" | "console" | "info", text}, oldest first.
        log: [],
        tabs: [],
        url: nil,
        title: nil,
        # Goes up with each new screenshot, so the page reloads it.
        shot: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.view, state}
  def handle_call(:screenshot, _from, state), do: {:reply, state.png, state}

  def handle_call({:open, opts}, _from, %{view: %{browser: "closed"}} = state) do
    debugger = self()
    driver = spawn(fn -> driver_loop(debugger) end)
    headless = Browser.headless?(opts)
    project = state.project

    state =
      %{state | driver: driver, monitor: Process.monitor(driver)}
      |> put_view(browser: "opening", headless: headless)
      |> log("info", "Opening Chrome#{if headless, do: " (headless)", else: ""}")
      |> job(:open, "Opening Chrome", fn ->
        case Browser.start(headless: headless, project: project, slow: if(headless, do: 0, else: 300)) do
          {:ok, browser} -> {:opened, browser.session}
          {:error, message} -> raise message
        end
      end)

    reply(state)
  end

  def handle_call({:open, _}, _from, state), do: {:reply, {:error, 409, "Chrome is already open"}, state}

  def handle_call(:close, _from, %{view: %{browser: "closed"}} = state), do: {:reply, {:ok, state.view}, state}

  def handle_call(:close, _from, state) do
    # The driver may be in the middle of something that won't end soon (a walkthrough's wait), so it isn't
    # asked: it goes, and the session is ended from here.
    Process.demonitor(state.monitor, [:flush])
    Process.exit(state.driver, :kill)
    if state.session, do: Browser.stop(state.session)
    reply(state |> closed() |> log("info", "Closed Chrome"))
  end

  def handle_call({:run, code}, _from, state) do
    code = String.trim(code)

    cond do
      code == "" ->
        {:reply, {:error, 400, "Type a command first"}, state}

      reason = refuse(state) ->
        {:reply, {:error, 409, reason}, state}

      true ->
        case command(code) do
          {:ok, call} ->
            reply(state |> log("command", code) |> job(:run, code, fn -> inspect(perform_call(call), pretty: true, limit: 50, printable_limit: 4000) end))

          {:error, message} ->
            {:reply, {:error, 400, message}, state}
        end
    end
  end

  def handle_call({:walk, name, opts}, _from, state) do
    cond do
      reason = refuse(state) ->
        {:reply, {:error, 409, reason}, state}

      match?(%{phase: p} when p in ["running", "paused"], state.view.walk) ->
        {:reply, {:error, 409, "The #{state.view.walk.name} walkthrough is still going: stop it first"}, state}

      true ->
        case Walkthrough.find(state.project, name) do
          {:ok, path} ->
            debugger = self()
            step = Keyword.get(opts, :step, false)

            state
            |> put_view(walk: %{name: name, phase: "running", step: nil, error: nil})
            |> log("info", "Walkthrough #{name}#{if step, do: ", a step at a time", else: ""}")
            |> job(:walk, "Walkthrough #{name}", fn -> walk_job(debugger, path, step) end)
            |> reply()

          {:error, message} ->
            {:reply, {:error, 404, message}, state}
        end
    end
  end

  def handle_call({:resume, how}, _from, %{view: %{walk: %{phase: "paused"}}} = state) do
    send(state.driver, {:resume, how})
    if how == :stop, do: reply(state), else: reply(put_in(state.view.walk.phase, "running"))
  end

  def handle_call({:resume, _}, _from, state), do: {:reply, {:error, 409, "No walkthrough is paused"}, state}

  def handle_call(:pause, _from, %{view: %{walk: %{phase: "running"}}} = state) do
    send(state.driver, :pause)
    reply(log(state, "info", "Pausing at the next caption"))
  end

  def handle_call(:pause, _from, state), do: {:reply, {:error, 409, "No walkthrough is running"}, state}

  def handle_call({:tab, which}, _from, state) do
    if reason = refuse(state),
      do: {:reply, {:error, 409, reason}, state},
      else: reply(job(state, :tab, "Tabs", fn -> tab_job(which) end))
  end

  # Why a command can't run now, or nil: the browser must be open, and a walkthrough mustn't be running
  # (at a pause is fine, the commands run there).
  defp refuse(state) do
    cond do
      state.view.browser != "open" -> "Open Chrome first"
      match?(%{phase: "running"}, state.view.walk) -> "A walkthrough is running: pause it first"
      true -> nil
    end
  end

  @impl true
  def handle_info({:done, id, result, snapshot}, %{jobs: jobs} = state) when is_map_key(jobs, id) do
    {kind, jobs} = Map.pop(jobs, id)
    state = %{state | jobs: jobs} |> put_view(busy: busy(jobs)) |> take(snapshot)

    state =
      case {kind, result} do
        {:open, {:ok, {:opened, session}}} -> %{state | session: session} |> put_view(browser: "open") |> log("info", "Chrome is open")
        {:open, {:error, message}} -> state |> log("error", message) |> stop_driver() |> closed()
        {:walk, {:ok, outcome}} -> walk_ended(state, outcome)
        {:walk, {:error, message}} -> walk_ended(state, {:failed, message})
        {:run, {:ok, value}} -> log(state, "result", value)
        {_, {:error, message}} -> log(state, "error", message)
        _ -> state
      end

    {:noreply, changed(state)}
  end

  def handle_info({:step, text, snapshot, paused}, %{view: %{walk: %{} = walk}} = state) do
    walk = %{walk | step: text, phase: if(paused, do: "paused", else: "running")}
    state = state |> put_view(walk: walk) |> take(snapshot) |> log("step", if(paused, do: "⏸ #{text}", else: text))
    {:noreply, changed(state)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{monitor: ref} = state) do
    state = if reason == :normal, do: closed(state), else: state |> closed() |> log("error", "Chrome's driver stopped: #{inspect(reason)}")
    {:noreply, changed(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp walk_ended(state, outcome) do
    name = state.view.walk.name

    {phase, error, text} =
      case outcome do
        :passed -> {"passed", nil, "✓ #{name} ran to the end"}
        :stopped -> {"stopped", nil, "Stopped #{name}"}
        {:failed, message} -> {"failed", message, "✕ #{name}: #{message}"}
      end

    state
    |> put_view(walk: %{state.view.walk | phase: phase, error: error})
    |> log(if(phase == "failed", do: "error", else: "info"), text)
  end

  defp job(state, kind, label, fun) do
    id = state.next
    send(state.driver, {:job, id, fun})
    jobs = Map.put(state.jobs, id, kind)
    %{state | next: id + 1, jobs: jobs} |> put_view(busy: busy(jobs) || if(kind != :walk, do: label))
  end

  # A walkthrough isn't counted: while it's paused, commands go on.
  defp busy(jobs) do
    case Enum.find(jobs, fn {_, kind} -> kind != :walk end) do
      {_, :open} -> "Opening Chrome"
      {_, _} -> "Working"
      nil -> nil
    end
  end

  defp take(state, nil), do: state

  defp take(state, snapshot) do
    state = Enum.reduce(snapshot.console, state, fn line, s -> log(s, "console", line) end)
    state = put_view(state, tabs: snapshot.tabs, url: snapshot.url, title: snapshot.title)
    if snapshot.png, do: %{state | png: snapshot.png} |> put_view(shot: state.view.shot + 1), else: state
  end

  defp closed(state) do
    %{state | driver: nil, monitor: nil, session: nil, jobs: %{}}
    |> put_view(browser: "closed", busy: nil, tabs: [], url: nil, title: nil)
    |> end_walk()
  end

  defp end_walk(%{view: %{walk: %{phase: p}}} = state) when p in ["running", "paused"], do: put_in(state.view.walk.phase, "stopped")
  defp end_walk(state), do: state

  defp stop_driver(state) do
    if state.driver, do: send(state.driver, :exit)
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    state
  end

  defp log(state, kind, text) do
    n = (List.last(state.view.log) || %{n: 0}).n + 1
    put_view(state, log: Enum.take(state.view.log ++ [%{n: n, kind: kind, text: text}], -@log_max))
  end

  defp put_view(state, changes), do: %{state | view: Map.merge(state.view, Map.new(changes))}

  defp reply(state) do
    state.on_change.(state.view)
    {:reply, {:ok, state.view}, state}
  end

  defp changed(state) do
    state.on_change.(state.view)
    state
  end

  # The driver: holds the browser, and runs the jobs it's sent one at a time.

  defp driver_loop(debugger) do
    receive do
      {:job, id, fun} ->
        run_job(debugger, id, fun)
        driver_loop(debugger)

      :exit ->
        Browser.stop()
    end
  end

  defp run_job(debugger, id, fun) do
    result = perform(fun)
    send(debugger, {:done, id, result, snapshot()})
  end

  defp perform(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error |> Exception.message() |> String.trim()}
  catch
    :throw, :clawswap_abort -> {:ok, :stopped}
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp walk_job(debugger, path, step) do
    Process.put(:debug_stepping, step)
    Browser.update(on_step: fn text -> at_step(debugger, text) end)

    try do
      case Walkthrough.eval_file(path) do
        :ok -> :passed
        {:error, message} -> {:failed, message}
      end
    after
      Browser.update(on_step: nil)
    end
  end

  # Each caption: tell the page, and wait there when stepping (or asked to pause), running the jobs sent
  # meanwhile.
  defp at_step(debugger, text) do
    receive do
      :pause -> Process.put(:debug_stepping, true)
    after
      0 -> :ok
    end

    paused = Process.get(:debug_stepping)
    send(debugger, {:step, text, snapshot(), paused})
    if paused, do: wait_at_step(debugger)
  end

  defp wait_at_step(debugger) do
    receive do
      {:job, id, fun} ->
        run_job(debugger, id, fun)
        wait_at_step(debugger)

      {:resume, :step} ->
        :ok

      {:resume, :continue} ->
        Process.put(:debug_stepping, false)

      {:resume, :stop} ->
        throw(:clawswap_abort)

      :pause ->
        wait_at_step(debugger)
    end
  end

  # Tabs. Closing one goes back to the tab that was in front before it, as a browser does, so a paused
  # walkthrough carries on in its own tab.
  defp tab_job(which) do
    session = Browser.session()
    {:ok, current} = WebdriverClient.window_handle(session)

    case which do
      :none ->
        :ok

      :new ->
        {:ok, %{"value" => %{"handle" => handle}}} = Wallaby.HTTPClient.request(:post, "#{session.session_url}/window/new", %{type: "tab"})
        focus(session, handle, current)

      :close ->
        {:ok, _} = WebdriverClient.close_window(session)
        {:ok, open} = WebdriverClient.window_handles(session)
        back = Enum.find(Process.get(:debug_tabs, []), &(&1 in open)) || List.last(open)
        Process.put(:debug_tabs, Enum.filter(Process.get(:debug_tabs, []), &(&1 in open and &1 != back)))
        if back, do: {:ok, _} = WebdriverClient.focus_window(session, back)

      handle when is_binary(handle) ->
        focus(session, handle, current)
    end

    :ok
  end

  defp focus(session, handle, current) do
    {:ok, _} = WebdriverClient.focus_window(session, handle)
    Wallaby.HTTPClient.request(:post, "#{session.session_url}/goog/cdp/execute", %{cmd: "Page.bringToFront", params: %{}})
    if handle != current, do: Process.put(:debug_tabs, [current | List.delete(Process.get(:debug_tabs, []), current)])
  end

  # What the page shows of the browser after a job: a screenshot, the tabs (Chrome's titles and addresses
  # for the session's window handles, which are its target ids), and new console lines.
  defp snapshot do
    case Browser.current() do
      %{session: session} ->
        handles = ok_or(try_or(fn -> WebdriverClient.window_handles(session) end, nil), [])
        current = ok_or(try_or(fn -> WebdriverClient.window_handle(session) end, nil), nil)

        targets =
          case try_or(fn -> Wallaby.HTTPClient.request(:post, "#{session.session_url}/goog/cdp/execute", %{cmd: "Target.getTargets", params: %{}}) end, nil) do
            {:ok, %{"value" => %{"targetInfos" => infos}}} -> Map.new(infos, &{&1["targetId"], &1})
            _ -> %{}
          end

        tabs =
          for handle <- handles do
            info = Map.get(targets, handle, %{})
            %{handle: handle, title: info["title"] || "", url: info["url"] || "", current: handle == current}
          end

        %{
          png: try_or(fn -> session.driver.take_screenshot(session) end, nil),
          tabs: tabs,
          url: ok_or(try_or(fn -> WebdriverClient.current_url(session) end, nil), nil),
          title: ok_or(try_or(fn -> WebdriverClient.page_title(session) end, nil), nil),
          console: console(session)
        }

      nil ->
        nil
    end
  end

  defp console(session) do
    case try_or(fn -> WebdriverClient.log(session) end, nil) do
      {:ok, entries} when is_list(entries) -> Enum.map(entries, &"#{&1["level"]} #{&1["message"]}")
      _ -> []
    end
  end

  defp ok_or({:ok, value}, _default), do: value
  defp ok_or(_, default), do: default

  defp try_or(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end
