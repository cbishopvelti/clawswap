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
