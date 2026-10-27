defmodule Clawswap.ZellijTest do
  use ExUnit.Case, async: true

  alias Clawswap.{Config, TestRepo, Zellij}

  test "writes a layout with the servers, the watcher and the other panes" do
    kdl = Zellij.layout(Config.normalise(TestRepo.bmx_config(), root: "/work/bmx"))
    for name <- ["phx", "vite", "clawswap", "docker"], do: assert(kdl =~ ~s(pane name="#{name}"))
    assert kdl =~ ~s(cwd="/work/bmx/backend" focus=true)
    assert kdl =~ ~s(args "iex -S mix phx.server")
    assert kdl =~ ~r{bin/clawswap" "watch"}
    # The servers come first, in the config's order.
    assert :binary.match(kdl, "\"phx\"") < :binary.match(kdl, "\"vite\"")
    # Quotes in commands survive.
    assert Zellij.layout(Config.normalise([panes: [q: [command: ~s(echo "hi")]]], root: "/r")) =~ ~s(args "echo \\"hi\\"")
  end

  test "needs zellij 0.44 or newer" do
    refute Zellij.version_ok?([0, 43, 1])
    assert Zellij.version_ok?([0, 44, 0])
    assert Zellij.version_ok?([1, 0, 0])
    refute Zellij.version_ok?(nil)
  end
end
