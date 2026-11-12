defmodule ClawswapWeb.Api do
  @moduledoc """
  The daemon's JSON API. Each project's is under /p/<id> (its id: `Clawswap.Config`'s, from its session's
  name); the same paths without it answer for the selected project (`Clawswap.Projects.selected/0`), so a
  Stream Deck key or a script that names no project follows whichever is selected.

      GET  /p/<id>/state                    the watcher's state (see README.md)
      GET  /p/<id>/events                   the same state as Server-Sent Events: now, then each time it
                                            changes, so a page can listen rather than poll /state
      POST /p/<id>/switch  {"branch": ...}  202, then follow /state's switch
      POST /p/<id>/pull                     the checkout's branch; 202 (switch.pull), or "Already up to date"
      POST /p/<id>/refresh                  look at GitHub now
      POST /p/<id>/claude  {"branch": ...}  open the Claude Code thread that made the branch (the checkout's
                                            without one) in the browser; 200 {"url": ...} or 404
      POST /p/<id>/walk    {"name": ...}    202, then follow /state's walk
      POST /p/<id>/smee    {"url": ...}     follow this smee.io channel from now on (clawswap smee sends it)
      POST /p/<id>/focus                    the project's page is in view: makes it the focused project, and
                                            selects it (the branch page and the debug panel send it); 200
                                            {project, root, at}
      GET  /p/<id>/debug/screenshot.png     the debug panel's last screenshot of its Chrome (404 when none)
      GET  /p/<id>/log                      the project's log, then each new line as it comes (the
                                            session's clawswap pane follows it; the project stays while one does)

      GET  /projects                        {"projects": [{id, name, root, port}], "selected": id,
                                            "focused": {project, root, at} or null}
      GET  /focus/events                    the focused project as Server-Sent Events: now, then each time
                                            a page reports, so a tool can follow the project you're looking at
      POST /select  {"project": id}         selects a project ({"next": true}: the one after the selected one)
      GET  /daemon                          {"clawswap": "daemon", "port": ..., "pid": ...}
      POST /daemon/projects {"cwd", "env"}  registers the project whose config is found from cwd, with the
                                            shell's environment (`clawswap up` and `clawswap watch` do)

  It answers this machine only, and browsers only from a project's origins (its servers', and any its
  config adds), for that project's paths: a page elsewhere can't make the browser send a JSON POST here
  without a preflight, which only those origins pass. Registering takes no browser at all, as it runs the
  config's code. The Host check stops DNS rebinding. Other paths go on to the pages.
  """

  @behaviour Plug

  import Plug.Conn

  alias Clawswap.{Project, ProjectLog, Projects, Watcher}

  @project_paths ["/state", "/switch", "/pull", "/refresh", "/claude", "/walk", "/smee", "/focus", "/debug/screenshot.png"]
  @daemon_paths ["/projects", "/select", "/daemon", "/daemon/projects", "/focus/events"]
  # The log's stream says something this often, so a pane that went away is noticed.
  @log_beat_ms 15_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    case route(path) do
      nil -> conn
      route -> serve(conn, route)
    end
  end

  # {:project, id or "selected", path} | {:daemon, path} | nil (a page's)
  defp route("/p/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [id, sub] when id != "" -> if(("/" <> sub) in ["/log", "/events" | @project_paths], do: {:project, id, "/" <> sub})
      _ -> nil
    end
  end

  defp route(path) when path in @project_paths, do: {:project, "selected", path}
  defp route(path) when path in @daemon_paths, do: {:daemon, path}
  defp route(_), do: nil

  defp serve(conn, route) do
    project = with {:project, id, _} <- route, do: Projects.get(id)
    port = Clawswap.Application.port() || conn.port
    origin = conn |> get_req_header("origin") |> List.first()
    own = ["http://localhost:#{port}", "http://127.0.0.1:#{port}"]
    origins = if is_map(project), do: MapSet.union(project.origins, MapSet.new(own)), else: MapSet.new(own)
    allowed = origin && MapSet.member?(origins, origin) && origin

    conn = if allowed, do: conn |> put_resp_header("access-control-allow-origin", allowed) |> put_resp_header("vary", "Origin"), else: conn

    cond do
      conn.host not in ["localhost", "127.0.0.1"] || (origin && !allowed) || (origin && route == {:daemon, "/daemon/projects"}) ->
        json(conn, 403, %{error: "Forbidden"})

      conn.method == "OPTIONS" ->
        conn
        |> put_resp_header("access-control-allow-methods", "GET, POST")
        |> put_resp_header("access-control-allow-headers", "Content-Type")
        |> send_resp(204, "")
        |> halt()

      match?({:project, _, _}, route) and project == nil ->
        {:project, id, _} = route
        json(conn, 404, %{error: if(id == "selected", do: "No projects yet (clawswap up starts one)", else: "No project #{id} (clawswap up starts it)")})

      true ->
        dispatch(conn, route, project)
    end
  end

  defp dispatch(conn, {:daemon, "/daemon"}, _), do: json(conn, 200, %{clawswap: "daemon", port: Clawswap.Application.port(), pid: System.pid()})
  defp dispatch(conn, {:daemon, "/projects"}, _), do: json(conn, 200, %{projects: Projects.list(), selected: Projects.selected(), focused: Projects.focused()})
  defp dispatch(conn, {:daemon, "/focus/events"}, _) when conn.method == "GET", do: stream_focus(conn)
  defp dispatch(conn, {:project, _, "/state"}, project) when conn.method == "GET", do: json(conn, 200, Watcher.state(watcher(project)))

  defp dispatch(conn, {:project, _, "/debug/screenshot.png"}, project) when conn.method == "GET" do
    case Clawswap.Walkthrough.Debugger.screenshot(Project.via(project.id, :debugger)) do
      nil -> json(conn, 404, %{error: "No screenshot yet"})
      png -> conn |> put_resp_header("content-type", "image/png") |> put_resp_header("cache-control", "no-store") |> send_resp(200, png) |> halt()
    end
  end

  defp dispatch(conn, {:project, _, "/log"}, project) when conn.method == "GET", do: follow_log(conn, project.id)
  defp dispatch(conn, {:project, _, "/events"}, project) when conn.method == "GET", do: stream_state(conn, project)

  defp dispatch(conn, route, project) do
    if conn.method != "POST" or not String.starts_with?(conn |> get_req_header("content-type") |> List.first() || "", "application/json") do
      json(conn, 404, %{error: "Not found"})
    else
      {:ok, body, conn} = read_body(conn, length: 4_000_000)
      post(conn, route, decode(body), project)
    end
  end

  defp post(conn, {:daemon, "/daemon/projects"}, body, _) do
    env = for {k, v} <- body["env"] || %{}, is_binary(k) and is_binary(v), into: %{}, do: {k, v}

    case body["cwd"] do
      cwd when is_binary(cwd) and cwd != "" ->
        case Projects.register(cwd, env) do
          {:ok, project} -> json(conn, 200, %{id: project.id, name: project.name, root: project.root, url: Clawswap.Config.url(project, :clawswap, "")})
          {:error, message} -> json(conn, 422, %{error: message})
        end

      _ ->
        json(conn, 400, %{error: ~s(Expected {"cwd": "...", "env": {...}})})
    end
  end

  defp post(conn, {:daemon, "/select"}, body, _) do
    result =
      if body["next"] == true, do: {:ok, Projects.select_next()}, else: with(:ok <- Projects.select(to_string(body["project"])), do: {:ok, body["project"]})

    case result do
      {:ok, nil} -> json(conn, 404, %{error: "No projects yet"})
      {:ok, id} -> json(conn, 200, %{selected: id})
      {:error, message} -> json(conn, 404, %{error: message})
    end
  end

  defp post(conn, {:project, _, "/refresh"}, _body, project), do: json(conn, 200, Watcher.refresh(watcher(project)))
  defp post(conn, {:project, _, "/switch"}, body, project), do: answer(conn, Watcher.switch_to(watcher(project), string(body["branch"])))
  defp post(conn, {:project, _, "/pull"}, _body, project), do: answer(conn, Watcher.pull(watcher(project)))

  defp post(conn, {:project, _, "/claude"}, body, project) do
    case Watcher.open_claude(watcher(project), string(body["branch"])) do
      {:ok, url} -> json(conn, 200, %{url: url})
      {:error, status, message} -> json(conn, status, %{error: message})
    end
  end

  defp post(conn, {:project, _, "/focus"}, _body, project) do
    case Projects.focus(project.id) do
      {:ok, focused} -> json(conn, 200, focused)
      {:error, message} -> json(conn, 404, %{error: message})
    end
  end

  defp post(conn, {:project, _, "/walk"}, body, project), do: answer(conn, Watcher.walk(watcher(project), string(body["name"])))

  defp post(conn, {:project, _, "/smee"}, body, project) do
    case body["url"] do
      "http" <> _ = url -> answer(conn, Watcher.set_smee(watcher(project), url))
      _ -> json(conn, 400, %{error: "Expected {\"url\": \"https://smee.io/...\"}"})
    end
  end

  defp post(conn, _route, _body, _project), do: json(conn, 404, %{error: "Not found"})

  defp decode(body) do
    case JSON.decode(if(body == "", do: "{}", else: body)) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp watcher(project), do: Project.via(project.id, :watcher)
  defp string(nil), do: ""
  defp string(value), do: to_string(value)

  @doc """
  A project's state changed (its watcher's on_change, through `ClawswapWeb.View.broadcast/2`): sends it to
  each open /p/<id>/events stream.
  """
  def notify(id, state) do
    if Process.whereis(Clawswap.Listeners),
      do: Registry.dispatch(Clawswap.Listeners, id, fn entries -> for {pid, _} <- entries, do: send(pid, {:clawswap_state, state}) end)

    :ok
  end

  # The state now, then each change, as Server-Sent Events, until the browser goes. A comment line every
  # beat (@log_beat_ms; config :events_beat_ms for tests) keeps proxies and idle timeouts from closing it, and notices a browser that went away.
  # A project that's gone ends the stream; the page's EventSource then gets a 404 and stops.
  defp stream_state(conn, project) do
    {:ok, _} = Registry.register(Clawswap.Listeners, project.id, nil)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    try do
      case event(conn, Watcher.state(watcher(project))) do
        {:ok, conn} -> state_loop(conn, project.id)
        {:error, _} -> halt(conn)
      end
    catch
      :exit, _ -> halt(conn)
    after
      Registry.unregister(Clawswap.Listeners, project.id)
    end
  end

  defp state_loop(conn, id) do
    receive do
      {:clawswap_state, state} -> next_event(conn, id, event(conn, state))
    after
      Application.get_env(:clawswap, :events_beat_ms, @log_beat_ms) ->
        if Projects.get(id), do: next_event(conn, id, chunk(conn, ": beat\n\n")), else: halt(conn)
    end
  end

  defp next_event(_conn, id, {:ok, conn}), do: state_loop(conn, id)
  defp next_event(conn, _id, {:error, _}), do: halt(conn)

  defp event(conn, state), do: chunk(conn, "data: " <> JSON.encode!(state) <> "\n\n")

  # The focused project now (null for none), then each time a page reports one, as Server-Sent Events,
  # until the client goes or the daemon's projects stop. Beats as /events does.
  defp stream_focus(conn) do
    {:ok, _} = Registry.register(Clawswap.Listeners, Projects.focus_listeners(), nil)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    try do
      case event(conn, Projects.focused()) do
        {:ok, conn} -> focus_loop(conn)
        {:error, _} -> halt(conn)
      end
    catch
      :exit, _ -> halt(conn)
    after
      Registry.unregister(Clawswap.Listeners, Projects.focus_listeners())
    end
  end

  defp focus_loop(conn) do
    receive do
      {:clawswap_focus, focused} -> next_focus(conn, event(conn, focused))
    after
      Application.get_env(:clawswap, :events_beat_ms, @log_beat_ms) ->
        if Process.whereis(Projects), do: next_focus(conn, chunk(conn, ": beat\n\n")), else: halt(conn)
    end
  end

  defp next_focus(_conn, {:ok, conn}), do: focus_loop(conn)
  defp next_focus(conn, {:error, _}), do: halt(conn)

  # The log so far, then each write as it comes, until the pane goes. A reload starts the project's log
  # again; the stream carries on with the new one.
  defp follow_log(conn, id) do
    :ok = Projects.attach(id)
    conn = conn |> put_resp_header("content-type", "text/plain; charset=utf-8") |> put_resp_header("cache-control", "no-store") |> send_chunked(200)

    try do
      log_loop(conn, id, attach_log(id))
    after
      Projects.detach(id)
    end
  end

  defp attach_log(id, tries \\ 50) do
    case Project.whereis(id, :log) do
      nil when tries > 0 ->
        Process.sleep(100)
        attach_log(id, tries - 1)

      nil ->
        nil

      log ->
        :ok = ProjectLog.attach(log)
        Process.monitor(log)
    end
  end

  defp log_loop(conn, _id, nil) do
    chunk(conn, "\e[36m[clawswap]\e[0m The project stopped\n")
    halt(conn)
  end

  defp log_loop(conn, id, ref) do
    receive do
      {:clawswap_log, text} ->
        continue(conn, id, ref, chunk(conn, text))

      {:DOWN, ^ref, :process, _, _} ->
        log_loop(conn, id, attach_log(id))
    after
      @log_beat_ms -> continue(conn, id, ref, chunk(conn, "\e[0m"))
    end
  end

  defp continue(_conn, id, ref, {:ok, conn}), do: log_loop(conn, id, ref)
  defp continue(conn, _id, _ref, {:error, _}), do: halt(conn)

  defp answer(conn, {:ok, state}), do: json(conn, 202, state)
  defp answer(conn, {:error, status, message}), do: json(conn, status, %{error: message})

  defp json(conn, status, body) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, JSON.encode!(body))
    |> halt()
  end
end
