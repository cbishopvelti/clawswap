defmodule Clawswap.Integration.DebugTest do
  # The debug panel, on the right of every page: a Chrome of its own that stays open, driven by hand and a caption at a time.
  use ExUnit.Case, async: false

  import Clawswap.Walkthrough.Script
  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 400_000

  setup do
    Integration.compile!()
    project = Integration.up!(Integration.project!(), :tmux)
    on_exit(fn -> Integration.down!(project) end)
    Integration.browser!(project)
    %{project: project}
  end

  test "the debug panel steps through a walkthrough and runs commands at a pause" do
    say "The branch page's debug panel opens a Chrome that stays open"
    visit url(:clawswap)
    click button("Open Chrome")
    see css("aside.debug .browser.open"), timeout: 60_000

    say "⏯ runs a walkthrough a caption at a time"
    click css("aside.debug .dwalk.step")
    see css("aside.debug .dwalk-status", text: "paused before: The example app"), timeout: 30_000

    say "Step goes on to the next caption"
    click button("Step")
    see css("aside.debug .dwalk-status", text: "paused before: The Branches menu"), timeout: 30_000

    say "At a pause, a command runs in the same browser, and the page shows what it returned"
    fill_in text_field("code"), with: ~s(js "return document.title")
    click button("Run")
    see css(".log li.command", text: ~s(js "return document.title")), timeout: 30_000
    see css(".log li.result"), timeout: 30_000

    say "Anything but a walkthrough command is refused"
    fill_in text_field("code"), with: ~s|File.rm_rf!("/tmp/x")|
    click button("Run")
    see css("aside.debug .dmessage", text: "Not a command")

    say "Continue runs it to the end, and Chrome stays open with a screenshot of how it ended"
    click button("Continue")
    see css("aside.debug .dwalk-status.passed", text: "branches-menu ran to the end"), timeout: 60_000
    see css(".shot img")
    see css(".tabs .tab.current")

    say "🐞 folds the panel away and back"
    click button("🐞")
    see css("aside.debug.folded")
    click button("🐞")

    say "Close Chrome closes it"
    click button("Close Chrome")
    see css("aside.debug .browser.closed")

    say "/panel is the panel alone, for an app's sidebar: the app folds it, so it has no 🐞"
    visit url(:clawswap, "/panel")
    see css("body.panel-only aside.debug .browser.closed")
    refute_see css("aside.debug .fold")
  end
end
