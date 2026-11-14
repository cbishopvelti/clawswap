defmodule Clawswap.RunTest do
  use ExUnit.Case, async: true

  alias Clawswap.Run

  describe "error_summary/1" do
    test "npm: the error, not the pointer to its log" do
      out = """
      npm error code E404
      npm error 404 Not Found - GET https://registry.npmjs.org/nope - Not found
      npm error 404
      npm error 404  'nope@*' is not in this registry.
      npm error 404
      npm error 404 Note that you can also install from a
      npm error 404 tarball, folder, http url, or git url.
      npm error A complete log of this run can be found in: /root/.npm/_logs/2026-11-14T01_00_00_000Z-debug-0.log
      """

      assert Run.error_summary(out) ==
               "404 Not Found - GET https://registry.npmjs.org/nope - Not found · 404  'nope@*' is not in this registry. · 404 Note that you can also install from a"
    end

    test "older npm's ERR! prefix, with colour codes" do
      out = """
      added 3 packages
      \e[31mnpm\e[0m \e[31mERR!\e[0m code ERESOLVE
      npm ERR! ERESOLVE unable to resolve dependency tree
      npm ERR!
      npm ERR! While resolving: app@1.0.0
      npm ERR! A complete log of this run can be found in:
      npm ERR!     /root/.npm/_logs/x-debug-0.log
      """

      assert Run.error_summary(out) == "ERESOLVE unable to resolve dependency tree · While resolving: app@1.0.0"
    end

    test "compiler and git errors" do
      assert Run.error_summary("Compiling 3 files (.ex)\nerror: undefined function foo/0\n  │\n** (CompileError) compilation failed\n") ==
               "error: undefined function foo/0 · ** (CompileError) compilation failed"

      assert Run.error_summary(
               "error: Your local changes to the following files would be overwritten by checkout:\n\tmix.lock\nPlease commit your changes or stash them before you switch branches.\nAborting\n"
             ) ==
               "error: Your local changes to the following files would be overwritten by checkout:"
    end

    test "the last line when nothing looks like an error" do
      assert Run.error_summary("building\nsomething went wrong\n\n") == "something went wrong"
      assert Run.error_summary("") == ""
    end
  end

  test "stream/3 fails with the error, not the last line" do
    script = "echo 'npm error code E1'; echo 'npm error boom'; echo 'npm error A complete log of this run can be found in: /x'; exit 1"
    assert Run.stream("sh", ["-c", script], write: fn _ -> :ok end) == {:error, "boom"}
  end

  test "capture/3 fails with stderr's error" do
    assert Run.capture("sh", ["-c", "echo 'fatal: not a git repository' >&2; echo hint >&2; exit 128"]) ==
             {:error, "fatal: not a git repository"}
  end
end
