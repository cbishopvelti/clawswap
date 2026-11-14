defmodule Clawswap.Integration.OverridesTest do
  # `clawswap up <name>` through bin/clawswap, as you'd run it: the name reaches mix clawswap up, so its
  # override config is layered over the project's, and a name with no override config is an error.
  use ExUnit.Case, async: false

  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 300_000

  setup do
    Integration.compile!()
    project = Integration.project!()
    on_exit(fn -> Integration.down!(project) end)
    %{project: project}
  end

  test "an unknown override name stops up before anything starts", %{project: project} do
    {out, code} = Integration.clawswap(project, ["up", "nope"], [{"CLAWSWAP_SESSION", project.session}])
    assert code == 1
    assert out =~ "No override config nope"
  end

  test "up <name> layers clawswap.<name>.exs over the config", %{project: project} do
    File.write!(Path.join(project.work, "clawswap.staging.exs"), ~s([name: "staging-example"]\n))
    Integration.up!(project, :tmux, "main", ["staging"])
    assert {:ok, %{"project" => "staging-example"}} = Integration.state()
  end
end
