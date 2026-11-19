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

  describe "gated" do
    @tag :tmp_dir
    test "runs the command at once when there's no gate", %{tmp_dir: dir} do
      [sh | args] = Multiplexer.gated(["echo", "started"], Path.join(dir, "gate"))
      assert {"started\n", 0} = System.cmd(sh, args)
    end

    @tag :tmp_dir
    test "says it's waiting while the gate is there, then runs the command once it's gone", %{tmp_dir: dir} do
      gate = Path.join(dir, "gate")
      File.write!(gate, "")
      [sh | args] = Multiplexer.gated(["echo", "started"], gate)

      port = Port.open({:spawn_executable, System.find_executable(sh)}, [:binary, :exit_status, args: args])
      assert_receive {^port, {:data, "Waiting for clawswap to catch up" <> _}}, 2_000
      refute_receive {^port, {:data, "started" <> _}}, 1_500
      File.rm!(gate)
      assert_receive {^port, {:data, "started\n"}}, 3_000
      assert_receive {^port, {:exit_status, 0}}, 2_000
    end

    test "without a gate, it's the command as it is" do
      assert Multiplexer.gated(["echo", "hi"], nil) == ["echo", "hi"]
    end
  end
end
