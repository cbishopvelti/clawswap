defmodule Clawswap.Integration.PageTest do
  # The watcher's page on its own and in the example app's Branches menu.
  use ExUnit.Case, async: false

  import Clawswap.Walkthrough.Script
  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 300_000

  setup_all do
    Integration.compile!()
    project = Integration.up!(Integration.project!(), :tmux)
    on_exit(fn -> Integration.down!(project) end)
    %{project: project}
  end

  setup %{project: project} do
    Integration.browser!(project)
    :ok
  end

  test "lists the branches with the base pinned first and merge marks" do
    say "The watcher's page: the base branch first, then the others by newest commit"
    visit url(:clawswap)
    see css("li:first-child .mark.base", text: "⎇")
    see css("li:first-child .status", text: "Current")

    say "✓ marks a branch merged into the base, ○ one that isn't"
    see css("li", text: "merged-fix")
    see css("li .mark.merged", text: "✓")
    see css("li", text: "new-heading")
    assert js(~s{return [...document.querySelectorAll("li")].find(li => li.textContent.includes("new-heading")).querySelector(".mark").textContent}) == "○"

    say "The ⚙ opens the config editor, and the page lists the checkout's walkthroughs"
    see css("a.settings-link[href='/settings']")
    see button("▶ branches-menu")
  end

  test "the example app's Branches menu frames the page as a compact list" do
    say "The example app embeds clawswap's page in an iframe"
    visit url(:web)
    see "Your app goes here"
    click "Branches"

    in_frame "iframe[title=clawswap]", fn ->
      see css("li.current", text: "main")
      see css("li", text: "new-heading")
      # The narrow layout: rows instead of cards, and no Stream Deck button.
      assert js(~s{return getComputedStyle(document.querySelector("li button")).borderTopWidth}) == "0px"
      assert js(~s{return getComputedStyle(document.querySelector(".deck")).display}) == "none"
    end

    say "The badge is the app's own control, on the JSON API"
    see css(".badge select")
    assert js(~s{return document.querySelector(".badge select").value}) == "main"
  end
end
