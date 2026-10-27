defmodule Clawswap.WatcherTest do
  # The watcher against a throwaway origin and clone, with stand-ins for the zellij panes and update steps.
  use ExUnit.Case

  alias Clawswap.{Config, TestRepo, Watcher}

  setup do
    repo = TestRepo.setup()
    project = Config.normalise(TestRepo.bmx_config(), root: repo.work)
    me = self()

    # No gh and no token, so the list is every branch.
    path = System.get_env("PATH")
    token = System.get_env("GITHUB_TOKEN")
    System.put_env("PATH", "/usr/bin:/bin")
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      System.put_env("PATH", path)
      if token, do: System.put_env("GITHUB_TOKEN", token)
      File.rm_rf!(repo.dir)
    end)

    start = fn opts ->
      servers = %{stop: fn name, _note -> send(me, {:call, "stop #{name}"}) end, start: fn name -> send(me, {:call, "start #{name}"}) end}

      start_supervised!(
        {Watcher,
         Keyword.merge(
           [
             name: nil,
             project: project,
             servers: servers,
             run_step: fn step -> send(me, {:call, step.name}) && :ok end,
             exit: &send(me, {:exit, &1}),
             quiet: true
           ],
           opts
         )}
      )
    end

    Map.merge(repo, %{project: project, start: start})
  end

  defp calls(acc \\ []) do
    receive do
      {:call, c} -> calls([c | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp finished?(w), do: match?(%{phase: p} when p != "running", Watcher.state(w).switch)

  test "lists branches, switches, runs only the needed steps and restarts the servers", %{work: work, start: start} do
    w = start.([])
    state = Watcher.refresh(w)
    assert Enum.map(state.branches, & &1.branch) == ["claude-main", "claude/new-thing"]
    assert Enum.at(state.branches, 1).short == "new-thing"
    assert state.current.branch == "claude-main"
    assert state.project == "bmx"

    assert {:ok, _} = Watcher.switch_to(w, "claude/new-thing")
    TestRepo.until(fn -> finished?(w) end)
    assert Watcher.state(w).switch.phase == "done"
    assert calls() == ["stop phx", "stop vite", "npm", "schema", "access", "start phx", "start vite"]
    TestRepo.until(fn -> Watcher.state(w).current.branch == "claude/new-thing" end)

    # An unknown branch is refused, and so is a switch with uncommitted changes.
    assert {:error, 404, _} = Watcher.switch_to(w, "nope")
    File.write!("#{work}/frontend/package.json", "{ }\n")
    assert {:error, 409, "Uncommitted" <> _} = Watcher.switch_to(w, "claude-main")
    assert Watcher.state(w).switch.phase == "failed"
  end

  test "restarts itself after a switch that changed the config", %{work: work, start: start} do
    TestRepo.write("#{work}/clawswap.exs", "[]\n")
    TestRepo.git(work, ["add", "."])
    TestRepo.git(work, ["commit", "-qm", "config"])
    TestRepo.git(work, ["push", "-q", "origin", "claude-main:claude/config"])
    TestRepo.git(work, ["reset", "-q", "--hard", "HEAD~1"])
    w = start.([])
    assert {:ok, _} = Watcher.switch_to(w, "claude/config")
    assert_receive {:exit, 75}, 5000
  end

  test "tells on_change about every change", %{start: start} do
    me = self()
    w = start.(on_change: &send(me, {:view, &1}))
    Watcher.refresh(w)
    assert_receive {:view, %{branches: [_ | _]}}
  end

  test "pulls the checkout's branch, and leaves the servers alone when there's nothing new", %{dir: dir, start: start} do
    w = start.([])
    assert {:ok, %{switch: %{notes: ["Already up to date"]}}} = Watcher.pull(w)
    assert calls() == []

    # Someone else pushes a deps change to claude-main.
    TestRepo.git(dir, ["clone", "-q", "origin.git", "other"])
    TestRepo.write("#{dir}/other/backend/mix.lock", "%{}\n")
    TestRepo.git("#{dir}/other", ["add", "."])
    TestRepo.git("#{dir}/other", ["commit", "-qm", "deps"])
    TestRepo.git("#{dir}/other", ["push", "-q", "origin", "claude-main"])

    assert {:ok, %{upstream: %{behind: 1}}} = Watcher.pull(w)
    TestRepo.until(fn -> finished?(w) end)
    assert Watcher.state(w).switch.phase == "done"
    assert calls() == ["stop phx", "stop vite", "deps", "start phx", "start vite"]
    TestRepo.until(fn -> Watcher.refresh(w).upstream.behind == 0 end)
  end
end
