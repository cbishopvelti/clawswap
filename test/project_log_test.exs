defmodule Clawswap.ProjectLogTest do
  use ExUnit.Case, async: true

  alias Clawswap.ProjectLog

  test "keeps what's printed through it, and sends it to who follows" do
    me = self()
    log = start_supervised!({ProjectLog, id: "shop", echo: &send(me, {:echo, &1})})
    task = Task.async(ProjectLog.wrap(fn -> IO.puts("one") && IO.write("tw") end, log))
    Task.await(task)
    assert_receive {:echo, "one\n"}
    :ok = ProjectLog.attach(log)
    assert_receive {:clawswap_log, "one\ntw"}
    Task.await(Task.async(ProjectLog.wrap(fn -> IO.puts("o ✓") end, log)))
    assert_receive {:clawswap_log, "o ✓\n"}
    assert ProjectLog.text(log) == "one\ntwo ✓\n"
  end
end
