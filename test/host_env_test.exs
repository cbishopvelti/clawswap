defmodule Clawswap.HostEnvTest do
  use ExUnit.Case, async: true

  alias Clawswap.HostEnv

  test "puts the host's PATH back and drops erl's own variables" do
    env = %{
      "CLAWSWAP_HOST_PATH" => "/home/me/.local/share/mise/installs/elixir/1.17/bin:/usr/bin",
      "PATH" => "/home/me/.local/share/mise/installs/elixir/1.19.6-otp-28/bin:/usr/bin",
      "ROOTDIR" => "/otp28",
      "BINDIR" => "/otp28/erts/bin",
      "EMU" => "beam",
      "PROGNAME" => "erl",
      "HOME" => "/home/me"
    }

    assert HostEnv.changes(env) == [
             {"PATH", "/home/me/.local/share/mise/installs/elixir/1.17/bin:/usr/bin"},
             {"ROOTDIR", nil},
             {"BINDIR", nil},
             {"EMU", nil},
             {"PROGNAME", nil}
           ]
  end

  test "puts the whole host environment back from CLAWSWAP_HOST_ENV's file" do
    # What mise exec and erl add for clawswap's own Elixir, over a shell whose mise had set its own.
    env = %{
      "CLAWSWAP_HOST_ENV" => "/tmp/host",
      "CLAWSWAP_HOST_PATH" => "/elixir-1.19.7/bin:/usr/bin",
      "CLAWSWAP_REPO" => "/repo",
      "PATH" => "/otp28/erts/bin:/elixir-1.19.6/bin:/usr/bin",
      "MIX_HOME" => "/elixir-1.19.6/.mix",
      "MIX_ARCHIVES" => "/elixir-1.19.6/.mix/archives",
      "__MISE_DIFF" => "abc",
      "ROOTDIR" => "/otp28",
      "HOME" => "/home/me"
    }

    file = "PATH=/elixir-1.19.7/bin:/usr/bin\0MIX_HOME=/elixir-1.19.7/.mix\0HOME=/home/me\0NOTE=two\nlines, a=b\0CLAWSWAP_EXEC=/tmp/outer\0"
    read = fn "/tmp/host" -> {:ok, file} end

    assert HostEnv.changes(env, read) == [
             {"MIX_HOME", "/elixir-1.19.7/.mix"},
             {"NOTE", "two\nlines, a=b"},
             {"PATH", "/elixir-1.19.7/bin:/usr/bin"},
             {"MIX_ARCHIVES", nil},
             {"ROOTDIR", nil},
             {"__MISE_DIFF", nil}
           ]
  end

  test "falls back to the PATH when CLAWSWAP_HOST_ENV's file can't be read or isn't an environment" do
    env = %{"CLAWSWAP_HOST_ENV" => "/tmp/gone", "CLAWSWAP_HOST_PATH" => "/mine", "PATH" => "/clawswap", "MIX_HOME" => "/x", "EMU" => "beam"}
    path_only = [{"PATH", "/mine"}, {"EMU", nil}]

    assert HostEnv.changes(env, fn _ -> {:error, :enoent} end) == path_only
    assert HostEnv.changes(env, fn _ -> {:ok, ""} end) == path_only
  end

  test "changes nothing without CLAWSWAP_HOST_PATH" do
    assert HostEnv.changes(%{"PATH" => "/usr/bin", "ROOTDIR" => "/otp"}) == []
    assert HostEnv.changes(%{"CLAWSWAP_HOST_PATH" => "", "ROOTDIR" => "/otp"}) == []
  end

  test "a project's commands get exactly the environment it was registered with" do
    host = %{"PATH" => "/project/bin", "DATABASE_URL" => "x", "ROOTDIR" => "/otp", "CLAWSWAP_EXEC" => "/tmp/x"}
    own = %{"PATH" => "/daemon/bin", "OTHER" => "daemon's", "ROOTDIR" => "/otp28"}

    assert HostEnv.for_project(host, own) == [
             {"DATABASE_URL", "x"},
             {"PATH", "/project/bin"},
             {"OTHER", nil},
             {"ROOTDIR", nil}
           ]

    assert HostEnv.for_project(nil, own) == []
  end
end
