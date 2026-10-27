defmodule Clawswap.WalkthroughTest do
  # Finding a checkout's walkthroughs, and the watcher running one (with a stand-in for the browser; the
  # real one is in test/integration).
  use ExUnit.Case

  alias Clawswap.{Config, TestRepo, Walkthrough, Watcher}

  import TestRepo, only: [git: 2, write: 2]

  setup do
    repo = TestRepo.setup()
    on_exit(fn -> File.rm_rf!(repo.dir) end)
    work = repo.work
    write("#{work}/walkthroughs/old.exs", "say \"old\"\n")
    git(work, ["add", "."])
    git(work, ["commit", "-qm", "old walkthrough"])
    git(work, ["push", "-q", "origin", "claude-main"])
    git(work, ["checkout", "-qb", "claude/walk"])
    write("#{work}/walkthroughs/new.exs", "say \"new\"\n")
    git(work, ["add", "."])
    git(work, ["commit", "-qm", "new walkthrough"])
    Map.put(repo, :project, Config.normalise(TestRepo.bmx_config(), root: work))
  end

  test "lists the walkthroughs, the branch's new ones first", %{project: project} do
    assert Walkthrough.list(project) == [
             %{name: "new", path: "walkthroughs/new.exs", new: true},
             %{name: "old", path: "walkthroughs/old.exs", new: false}
           ]

    assert Walkthrough.list(%{project | walkthroughs: "elsewhere"}) == []
  end

  test "the watcher runs one at a time, and keeps how it went", %{project: project} do
    me = self()

    run_walk = fn _project, name, opts ->
      send(me, {:walking, name, self()})
      opts[:on_step].("First caption")

      receive do
        :pass -> :ok
        :fail -> {:error, "line 2: Didn't see \"x\""}
      end
    end

    servers = %{stop: fn _, _ -> :ok end, start: fn _ -> :ok end}

    w =
      start_supervised!(
        {Watcher, name: nil, project: project, servers: servers, run_step: fn _ -> :ok end, run_walk: run_walk, refresh_git: false, quiet: true}
      )

    assert Enum.map(Watcher.refresh(w).walkthroughs, & &1.name) == ["new", "old"]
    assert {:error, 404, _} = Watcher.walk(w, "missing")

    assert {:ok, %{walk: %{name: "new", phase: "running"}}} = Watcher.walk(w, "new")
    assert_receive {:walking, "new", walker}
    assert {:error, 409, "Already running the new walkthrough"} = Watcher.walk(w, "old")
    TestRepo.until(fn -> Watcher.state(w).walk.step == "First caption" end)
    send(walker, :pass)
    TestRepo.until(fn -> Watcher.state(w).walk.phase == "passed" end)

    {:ok, _} = Watcher.walk(w, "old")
    assert_receive {:walking, "old", walker}
    send(walker, :fail)
    TestRepo.until(fn -> Watcher.state(w).walk.phase == "failed" end)
    assert Watcher.state(w).walk.error == "line 2: Didn't see \"x\""
  end
end
