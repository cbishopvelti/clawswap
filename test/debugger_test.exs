defmodule Clawswap.Walkthrough.DebuggerTest do
  use ExUnit.Case, async: true

  alias Clawswap.Walkthrough.Debugger

  describe "command/1" do
    test "reads one walkthrough command with literal arguments" do
      assert {:ok, {:call, :click, ["Ping"]}} = Debugger.command(~s(click "Ping"))
      assert {:ok, {:call, :see, ["pong", [timeout: 5000]]}} = Debugger.command(~s(see "pong", timeout: 5000))
      assert {:ok, {:call, :js, ["return document.title"]}} = Debugger.command(~s(js "return document.title"))
      assert {:ok, {:call, :pause, []}} = Debugger.command("pause")
    end

    test "takes queries and url/2 as arguments" do
      assert {:ok, {:call, :visit, [{:call, :url, [:web, "/x"]}]}} = Debugger.command(~s|visit url(:web, "/x")|)
      assert {:ok, {:call, :see, [{:call, :css, [".log", [text: "pong"]]}]}} = Debugger.command(~s|see css(".log", text: "pong")|)
    end

    test "runs nothing else" do
      for code <- [
            ~s|File.rm_rf!("/tmp/x")|,
            ~s|System.cmd("true", [])|,
            ~s|click "a"; click "b"|,
            ~s|click(x)|,
            ~s|apply(IO, :puts, ["x"])|,
            ~s|visit "a" <> "b"|
          ] do
        assert {:error, message} = Debugger.command(code), code
        assert is_binary(message)
      end
    end

    test "checks how many arguments a command takes" do
      assert {:error, "click takes 1 or 2 arguments"} = Debugger.command("click")
    end
  end

  test "commands, walkthroughs and tabs wait for Chrome to be open" do
    {:ok, debugger} = Debugger.start_link(name: nil, project: nil)
    assert %{browser: "closed"} = Debugger.state(debugger)
    assert {:error, 409, "Open Chrome first"} = Debugger.run(debugger, ~s(click "Ping"))
    assert {:error, 409, "Open Chrome first"} = Debugger.walk(debugger, "x", [])
    assert {:error, 409, "No walkthrough is paused"} = Debugger.resume(debugger, :step)
    assert Debugger.screenshot(debugger) == nil
  end
end
