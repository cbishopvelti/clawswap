defmodule Clawswap.BrowserTestsTest do
  # Finding a project's browser tests, and the servers' addresses they use (running them is in
  # test/integration).
  use ExUnit.Case, async: true

  alias Clawswap.{BrowserTests, Config}

  setup do
    root = Path.join(System.tmp_dir!(), "clawswap-bt-#{System.unique_integer([:positive])}")

    for f <- ["browser_tests/a_test.exs", "browser_tests/chat/b_test.exs", "browser_tests/test_helper.exs"],
        do: File.mkdir_p!(Path.dirname(Path.join(root, f))) && File.write!(Path.join(root, f), "")

    on_exit(fn -> File.rm_rf!(root) end)
    config = [port: 27390, servers: [web: [command: "mix phx.server", port: 4000], api: [command: "api", port: 4001]]]
    %{root: root, project: Config.normalise(config, root: root)}
  end

  test "every *_test.exs in the folder, or those named", %{root: root, project: project} do
    assert BrowserTests.files(project, []) == {:ok, [Path.join(root, "browser_tests/a_test.exs"), Path.join(root, "browser_tests/chat/b_test.exs")]}
    assert BrowserTests.files(project, ["chat"], Path.join(root, "browser_tests")) == {:ok, [Path.join(root, "browser_tests/chat/b_test.exs")]}
    assert BrowserTests.files(project, ["browser_tests/nope_test.exs"]) == {:error, "No such file or folder: browser_tests/nope_test.exs"}
    assert {:error, "No browser tests (*_test.exs) in elsewhere/ yet"} = BrowserTests.files(%{project | browser_tests: "elsewhere"}, [])
  end

  test "url/3 finds a server's port by name", %{project: project} do
    assert Config.url(project, nil, "/chat") == "http://localhost:4000/chat"
    assert Config.url(project, :api, "/") == "http://localhost:4001/"
    assert Config.url(project, :clawswap, "/state") == "http://localhost:27390/p/#{project.id}/state"
    assert_raise RuntimeError, "No server called nope", fn -> Config.url(project, :nope, "/") end
  end
end
