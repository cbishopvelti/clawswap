defmodule Clawswap.ProjectsTest do
  # The daemon's projects, against throwaway repos: registering, the selection, the log, a reload, and
  # going away when no pane follows a project. Then the API in front of them.
  use ExUnit.Case

  import Plug.Test
  import Plug.Conn

  alias Clawswap.{Project, ProjectLog, Projects, TestRepo, Watcher}

  setup do
    # No gh and no token, so the lists are every branch.
    path = System.get_env("PATH")
    token = System.get_env("GITHUB_TOKEN")
    System.put_env("PATH", "/usr/bin:/bin")
    System.delete_env("GITHUB_TOKEN")

    repos =
      for session <- ["shop", "blog"] do
        repo = TestRepo.setup()

        TestRepo.write(
          Path.join(repo.work, "clawswap.exs"),
          ~s([name: "#{session}", session: "#{session}", base: "claude-main", multiplexer: "tmux", servers: [web: [command: "true", port: 4000]]]\n)
        )

        repo
      end

    on_exit(fn ->
      System.put_env("PATH", path)
      if token, do: System.put_env("GITHUB_TOKEN", token)
      Enum.each(repos, &File.rm_rf!(&1.dir))
    end)

    me = self()

    start_supervised!(
      {Projects,
       detached_ms: 200,
       first_attach_ms: 60_000,
       on_change: fn -> send(me, :projects_changed) end,
       project_opts: [refresh_git: false, quiet: true, echo: nil, on_change: fn id, view -> send(me, {:view, id, view}) end]}
    )

    %{repos: repos, env: %{"PATH" => "/usr/bin:/bin", "HOME" => System.get_env("HOME"), "DIRECT" => "shop's"}}
  end

  test "runs each project once, by its session's id, and selects the first", %{repos: [shop, blog], env: env} do
    assert {:ok, %{id: "shop", root: root}} = Projects.register(shop.work, env)
    assert root == shop.work
    assert {:ok, %{id: "blog"}} = Projects.register(Path.join(blog.work, "frontend"), env)
    assert_receive {:view, "shop", %{project: "shop", id: "shop"}}, 5000
    # Registering again (the pane's watch, after up) changes nothing.
    assert {:ok, %{id: "shop"}} = Projects.register(shop.work, env)
    assert Enum.map(Projects.list(), & &1.id) == ["shop", "blog"]
    assert Projects.selected() == "shop"
    assert Projects.get("selected").id == "shop"
    assert Projects.cached(:selected) == "shop"

    # Each has its own watcher.
    assert Watcher.state(Project.via("blog", :watcher)).project == "blog"

    assert Projects.select_next() == "blog"
    assert Projects.get(nil).id == "blog"
    assert Projects.select_next() == "shop"
    assert Projects.select("nope") == {:error, "No project nope"}
    assert :ok = Projects.select("blog")
    assert_receive :projects_changed

    :ok = Projects.unregister("blog")
    assert Projects.selected() == "shop"
    assert Project.whereis("blog", :watcher) == nil
  end

  test "another checkout can't take a project's id", %{repos: [shop, blog], env: env} do
    TestRepo.write(Path.join(blog.work, "clawswap.exs"), ~s([name: "shop", base: "claude-main", multiplexer: "tmux"]\n))
    {:ok, _} = Projects.register(shop.work, env)
    assert {:error, message} = Projects.register(blog.work, env)
    assert message =~ "already running as shop"
  end

  test "a project's commands get the environment it was registered with", %{repos: [shop, _], env: env} do
    {:ok, project} = Projects.register(shop.work, env)
    assert project.host_env["DIRECT"] == "shop's"
    step = %{name: "env", cmd: "sh", args: ["-c", "echo $DIRECT"], cwd: "."}
    log = Project.whereis("shop", :log)
    ProjectLog.attach(log)
    task = Task.async(ProjectLog.wrap(fn -> Watcher.step_runner(project).(step) end, log))
    assert Task.await(task) == :ok
    TestRepo.until(fn -> ProjectLog.text(log) =~ "env | shop's" end)
  end

  test "what a project's watcher prints goes to its log, and to the panes following it", %{repos: [shop, _], env: env} do
    {:ok, _} = Projects.register(shop.work, env)
    log = Project.whereis("shop", :log)
    :ok = ProjectLog.attach(log)
    assert_receive {:clawswap_log, _so_far}

    # A switch logs from a task the watcher starts.
    Watcher.switch_to(Project.via("shop", :watcher), "claude/new-thing")
    assert_receive {:clawswap_log, "\e[36m[clawswap]\e[0m Switching to claude/new-thing\n"}, 5000
    TestRepo.until(fn -> ProjectLog.text(log) =~ "Switching to claude/new-thing" end)
  end

  test "a reload starts the project again on its config as it is now", %{repos: [shop, _], env: env} do
    {:ok, _} = Projects.register(shop.work, env)
    before = Project.whereis("shop", :watcher)
    TestRepo.write(Path.join(shop.work, "clawswap.exs"), ~s([name: "Shop", session: "shop", base: "claude-main", multiplexer: "tmux"]\n))
    Projects.reload("shop")
    TestRepo.until(fn -> (pid = Project.whereis("shop", :watcher)) && pid != before end)
    assert Projects.get("shop").name == "Shop"

    # A config that doesn't load leaves it running as it was.
    still = Project.whereis("shop", :watcher)
    TestRepo.write(Path.join(shop.work, "clawswap.exs"), "[name: \n")
    Projects.reload("shop")
    Process.sleep(300)
    assert Project.whereis("shop", :watcher) == still
  end

  test "a project goes once no pane has followed it for a while", %{repos: [shop, _], env: env} do
    {:ok, _} = Projects.register(shop.work, env)
    pane = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Projects.attach("shop", pane)
    Process.sleep(400)
    assert Projects.get("shop")
    Process.exit(pane, :kill)
    TestRepo.until(fn -> Projects.get("shop") == nil end)
  end

  describe "the API" do
    defp api(method, path, body \\ nil, headers \\ []) do
      conn = conn(method, path, body && JSON.encode!(body))
      {host, headers} = Keyword.pop(headers, :host, "127.0.0.1")
      conn = Enum.reduce(headers, %{conn | host: host, port: 27390}, fn {k, v}, c -> put_req_header(c, k, v) end)
      conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn
      conn = ClawswapWeb.Api.call(conn, [])
      {conn.status, conn.resp_body && JSON.decode!(conn.resp_body)}
    end

    test "registers projects, and answers for each under /p/<id> and for the selected one without", %{repos: [shop, blog], env: env} do
      assert {404, %{"error" => "No projects yet" <> _}} = api(:get, "/state")
      assert {200, %{"id" => "shop", "url" => "http://localhost:27390/p/shop"}} = api(:post, "/daemon/projects", %{cwd: shop.work, env: env})
      assert {200, %{"id" => "blog"}} = api(:post, "/daemon/projects", %{cwd: blog.work, env: env})
      assert {422, %{"error" => "Not in a git checkout"}} = api(:post, "/daemon/projects", %{cwd: System.tmp_dir!(), env: env})

      assert {200, %{"project" => "blog"}} = api(:get, "/p/blog/state")
      assert {200, %{"project" => "shop"}} = api(:get, "/state")
      assert {404, %{"error" => "No project nope" <> _}} = api(:get, "/p/nope/state")
      assert {200, %{"projects" => [%{"id" => "shop"}, %{"id" => "blog"}], "selected" => "shop"}} = api(:get, "/projects")

      assert {200, %{"selected" => "blog"}} = api(:post, "/select", %{next: true})
      assert {200, %{"project" => "blog"}} = api(:get, "/state")
      assert {200, %{"selected" => "shop"}} = api(:post, "/select", %{project: "shop"})
      assert {404, _} = api(:post, "/select", %{project: "nope"})

      assert {404, %{"error" => "isn't one of the listed branches" <> _}} =
               api(:post, "/p/blog/switch", %{branch: "nope"}) |> then(fn {s, b} -> {s, %{"error" => String.replace(b["error"], "nope ", "")}} end)
    end

    test "streams a project's state at /p/<id>/events: now, then each change, until the project goes", %{repos: [shop, _], env: env} do
      {:ok, _} = Projects.register(shop.work, env)
      Application.put_env(:clawswap, :events_beat_ms, 100)
      on_exit(fn -> Application.delete_env(:clawswap, :events_beat_ms) end)

      stream =
        Task.async(fn ->
          conn = %{conn(:get, "/p/shop/events") | host: "127.0.0.1", port: 27390} |> put_req_header("origin", "http://localhost:4000")
          ClawswapWeb.Api.call(conn, [])
        end)

      TestRepo.until(fn -> Registry.lookup(Clawswap.Listeners, "shop") != [] end)
      ClawswapWeb.Api.notify("shop", %{project: "shop", switch: %{phase: "done", doneAt: 7}})
      ClawswapWeb.Api.notify("blog", %{project: "blog"})
      :ok = Projects.unregister("shop")
      conn = Task.await(stream, 5000)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:4000"]

      events = for "data: " <> json <- String.split(conn.resp_body, "\n\n", trim: true), do: JSON.decode!(json)
      assert [%{"project" => "shop"}, %{"switch" => %{"doneAt" => 7}}] = events
      assert Registry.lookup(Clawswap.Listeners, "shop") == []
    end

    test "only a project's own origins may call its paths, and no page may register a project", %{repos: [shop, _], env: env} do
      {:ok, _} = Projects.register(shop.work, env)
      assert {200, _} = api(:get, "/p/shop/state", nil, [{"origin", "http://localhost:4000"}])
      assert {403, _} = api(:get, "/p/shop/state", nil, [{"origin", "http://localhost:5000"}])
      assert {403, _} = api(:post, "/daemon/projects", %{cwd: shop.work, env: env}, [{"origin", "http://127.0.0.1:27390"}])
      assert {403, _} = api(:get, "/p/shop/state", nil, host: "evil.example")
    end
  end
end
