defmodule Clawswap.Integration.BrowserTestsTest do
  # `clawswap test`: the example's Wallaby features (examples/react-embed/browser_tests), one of them with
  # two sessions, against the dev server the session runs.
  use ExUnit.Case, async: false

  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 400_000

  setup do
    Integration.compile!()
    project = Integration.up!(Integration.project!(), :tmux)
    on_exit(fn -> Integration.down!(project) end)
    %{project: project}
  end

  defp headless, do: [{"CLAWSWAP_HEADLESS", System.get_env("CLAWSWAP_HEADLESS") || "1"}]

  test "clawswap test runs the project's features, several sessions and all", %{project: project} do
    {out, code} = Integration.clawswap(project, ["test"], headless())
    assert code == 0, out
    assert out =~ "3 features, 0 failures"
  end

  test "a failing feature fails the run, with a screenshot; --only picks features by tag", %{project: project} do
    File.write!(Path.join(project.work, "browser_tests/broken_test.exs"), """
    defmodule BrokenTest do
      use Clawswap.Feature

      @tag :broken
      feature "looks for a heading that isn't there", %{session: session} do
        session |> visit(url("/")) |> assert_has(css("h1", text: "Not on this page"))
      end
    end
    """)

    {out, 1} = Integration.clawswap(project, ["test", "--only", "broken"], headless())
    assert out =~ "1 feature, 1 failure"
    assert out =~ "Not on this page"
    assert out =~ "clawswap-screenshots"

    {out, 1} = Integration.clawswap(project, ["test", "browser_tests/broken_test.exs"], headless())
    assert out =~ "1 feature, 1 failure"

    {out, 1} = Integration.clawswap(project, ["test", "browser_tests/missing_test.exs"], headless())
    assert out =~ "No such file or folder: browser_tests/missing_test.exs"
  end
end
