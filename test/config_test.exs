defmodule Clawswap.ConfigTest do
  use ExUnit.Case

  alias Clawswap.{Config, TestRepo}

  test "fills in the defaults" do
    p = Config.normalise([servers: [web: [command: "npm run dev", port: 3000]]], root: "/home/me/shop", base: "trunk")
    assert p.name == "shop"
    assert p.session == "shop"
    assert p.base == "trunk"
    assert p.port == 8790
    assert MapSet.to_list(p.origins) |> Enum.sort() == ["http://127.0.0.1:3000", "http://localhost:3000"]
    assert p.short_name.("claude/fix-it") == "fix-it"
    assert p.restart.("clawswap.exs")
    assert p.server_names == ["web"]
  end

  test "refuses a pane named like a server" do
    assert_raise ArgumentError, ~r/taken/, fn ->
      Config.normalise([servers: [a: [command: "x"]], panes: [a: [command: "y"]]], root: "/r")
    end
  end

  test "loads the repo's config, with state kept in .git" do
    %{dir: dir, work: work} = TestRepo.setup()

    try do
      assert {:error, "No clawswap.exs" <> _} = Config.load("#{work}/frontend")
      File.cp!(Path.expand("../examples/bmx.exs", __DIR__), "#{work}/clawswap.exs")
      {:ok, project} = Config.load("#{work}/frontend")
      assert project.root == String.trim(TestRepo.git(work, ["rev-parse", "--show-toplevel"]))
      assert project.base == "claude-main"
      assert project.local_file == Path.join(project.root, ".git/clawswap.json")
      assert project.server_names == ["phx", "vite"]
    after
      File.rm_rf!(dir)
    end
  end

  test "loads the closest clawswap.exs above the folder it's run from" do
    %{dir: dir, work: work} = TestRepo.setup()

    try do
      File.write!("#{work}/clawswap.exs", ~s([name: "root"]))
      File.write!("#{work}/frontend/clawswap.exs", ~s([name: "frontend"]))
      File.mkdir_p!("#{work}/frontend/src")
      assert {:ok, %{name: "frontend", file: "frontend/clawswap.exs"} = p} = Config.load("#{work}/frontend/src")
      assert p.restart.("frontend/clawswap.exs")
      assert Clawswap.Zellij.layout(p) =~ ~r/name="clawswap".* cwd="#{Regex.escape(p.root)}\/frontend"/
      assert {:ok, %{name: "root", file: "clawswap.exs"}} = Config.load(work)
    after
      File.rm_rf!(dir)
    end
  end

  test "catches up from the last updated commit, or runs everything the first time" do
    %{dir: dir, work: work} = TestRepo.setup()
    project = Config.normalise(TestRepo.bmx_config(), root: work)

    try do
      assert {_, steps} = Config.pending_steps(project)
      assert length(steps) == 6
      head = String.trim(TestRepo.git(work, ["rev-parse", "HEAD"]))
      Config.mark_updated(project, head)
      assert Config.pending_steps(project) == {head, []}
      TestRepo.write("#{work}/backend/mix.lock", "%{}\n")
      TestRepo.git(work, ["add", "backend"])
      TestRepo.git(work, ["commit", "-qm", "deps"])
      assert {_, [%{name: "deps"}]} = Config.pending_steps(project)
    after
      File.rm_rf!(dir)
    end
  end
end
