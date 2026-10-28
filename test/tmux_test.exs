defmodule Clawswap.TmuxTest do
  use ExUnit.Case, async: true

  alias Clawswap.{Config, Multiplexer, TestRepo, Tmux, Zellij}

  test "builds the servers on the left, the watcher and the other panes on the right" do
    cmds = Tmux.commands(Config.normalise(TestRepo.bmx_config(), root: "/work/bmx"))
    names = for ["set-option", "-p", "-t", "=bmx:", "@clawswap", n] <- cmds, do: n
    assert names == ["phx", "clawswap", "docker", "shell", "vite"]
    assert ["new-session", "-s", "bmx", "-n", "bmx", "-c", "/work/bmx/backend", "--", _keep, "iex -S mix phx.server"] = hd(cmds)
    assert Enum.any?(cmds, &match?(["split-window", "-h", "-t", "=bmx:", "-l", "40%" | _], &1))
    assert List.last(cmds) == ["select-pane", "-t", "=bmx:.{top-left}"]
  end

  test "a pane with no command is a plain shell" do
    assert ["split-window", "-v", "-t", "=r:", "-l", "50%", "-c", "/r"] in Tmux.commands(Config.normalise([panes: [shell: nil]], root: "/r"))
    assert Config.normalise([panes: [shell: [command: ""]]], root: "/r").panes["shell"].command == nil
  end

  test "splits a column evenly" do
    p = Config.normalise([panes: [a: [command: "a"], b: [command: "b"], c: [command: "c"]]], root: "/r")
    assert for(["split-window", "-v", "-t", "=r:", "-l", size | _] <- Tmux.commands(p), do: size) == ["75%", "66%", "50%"]
  end

  test "keeps a ; at the end of an argument" do
    assert Tmux.layout(Config.normalise([servers: [w: [command: "echo hi;"]]], root: "/r")) =~ ~S('echo hi\;')
  end

  test "needs tmux 3.1 or newer" do
    refute Tmux.version_ok?([3, 0])
    assert Tmux.version_ok?([3, 1])
    assert Tmux.version_ok?([4, 0])
    refute Tmux.version_ok?(nil)
  end

  test "picks the configured multiplexer, else the one it runs in, else what's installed" do
    p = Config.normalise([], root: "/r")
    none = fn _ -> false end
    assert Multiplexer.pick(%{p | multiplexer: :tmux}, %{"ZELLIJ" => "0"}, none) == Tmux
    assert Multiplexer.pick(%{p | multiplexer: "zellij"}, %{"TMUX" => "x"}, none) == Zellij
    assert Multiplexer.pick(p, %{"TMUX" => "x"}, none) == Tmux
    assert Multiplexer.pick(p, %{"ZELLIJ" => "0"}, none) == Zellij
    assert Multiplexer.pick(%{p | layout: "my.kdl"}, %{}, &(&1 == Tmux)) == Zellij
    assert Multiplexer.pick(p, %{}, &(&1 == Tmux)) == Tmux
    assert Multiplexer.pick(p, %{}, fn _ -> true end) == Zellij
    assert_raise ArgumentError, fn -> Multiplexer.pick(%{p | multiplexer: :screen}, %{}, none) end
  end

  test "takes the multiplexer from a YAML config" do
    %{dir: dir, work: work} = TestRepo.setup()

    try do
      File.write!("#{work}/clawswap.yml", "multiplexer: tmux\n")
      assert {:ok, p} = Config.load(work)
      assert Multiplexer.pick(p, %{"ZELLIJ" => "0"}, fn _ -> true end) == Tmux
    after
      File.rm_rf!(dir)
    end
  end
end
