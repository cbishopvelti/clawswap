defmodule Clawswap.MultiplexerTest do
  use ExUnit.Case, async: true

  alias Clawswap.Multiplexer

  test "hold shows the note and keeps running, without sleep infinity (BSD and macOS sleep reject it)" do
    [sh, "-c", script, "sh", "Switching to main..."] = Multiplexer.hold("Switching to main...")
    refute script =~ "sleep"

    port = Port.open({:spawn_executable, System.find_executable(sh)}, [:binary, :exit_status, args: ["-c", script, "sh", "Switching to main..."]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    assert_receive {^port, {:data, "Switching to main...\n"}}, 2_000
    refute_receive {^port, {:exit_status, _}}, 500
    System.cmd("kill", ["-TERM", to_string(pid)])
    assert_receive {^port, {:exit_status, _}}, 2_000
  end
end
