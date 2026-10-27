for multiplexer <- [:zellij, :tmux] do
  defmodule Module.concat(Clawswap.Integration.SwitchTest, Macro.camelize(to_string(multiplexer))) do
    # A switch from the example app's menu: the dev server stops, the branch is checked out and the app
    # comes back with the change. Then back again with the badge.
    use ExUnit.Case, async: false

    import Clawswap.Walkthrough.Script
    alias Clawswap.Integration

    @moduletag :integration
    @moduletag timeout: 400_000
    @multiplexer multiplexer

    setup do
      Integration.compile!()
      project = Integration.up!(Integration.project!(), @multiplexer)
      on_exit(fn -> Integration.down!(project) end)
      Integration.browser!(project)
      :ok
    end

    test "switching branch restarts the app's server in #{multiplexer}" do
      say "Switch to claude/new-heading from the Branches menu (#{@multiplexer})"
      visit url(:web)
      see "Your app goes here"
      click "Branches"
      in_frame "iframe[title=clawswap]", fn -> click css("li button", text: "new-heading") end

      say "clawswap stops the dev server, checks out the branch and starts it again"
      Integration.wait_for_branch("claude/new-heading")
      see Integration.heading(), timeout: 60_000

      say "Back to main with the badge in the top bar"
      choose css(".badge select"), "main"
      Integration.wait_for_branch("main")
      see "Your app goes here", timeout: 60_000
    end
  end
end
