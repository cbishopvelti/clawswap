defmodule Clawswap.Integration.SettingsTest do
  # The config editor: a save writes clawswap.exs and restarts the watcher on it.
  use ExUnit.Case, async: false

  import Clawswap.Walkthrough.Script
  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 300_000

  setup do
    Integration.compile!()
    project = Integration.up!(Integration.project!(), :tmux)
    on_exit(fn -> Integration.down!(project) end)
    Integration.browser!(project)
    %{project: project}
  end

  test "saving the config editor renames the project", %{project: project} do
    say "The config editor, from the ⚙ on the page"
    visit url(:clawswap, "/settings")
    see "Settings"
    see css(".file", text: "clawswap.exs")

    say "Rename the project and save"
    fill_in "the repo folder's name", with: "renamed-example"
    click button("Save")
    see "Saved. The watcher is restarting with it.", timeout: 20_000
    assert File.read!(Path.join(project.work, "clawswap.exs")) =~ ~s(name: "renamed-example")

    say "The watcher restarts on the new config"
    Integration.wait_for(fn -> match?({:ok, %{"project" => "renamed-example"}}, Integration.state()) end, 120_000, "the restart")
    visit url(:clawswap)
    see css("h1", text: "renamed-example")
  end
end
