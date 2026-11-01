# Browser tests for the example: Wallaby features run by `clawswap test`, against the dev server the
# session runs. See README.md's Browser tests.
defmodule ReactEmbed.AppTest do
  use Clawswap.Feature, async: true

  feature "the badge shows the checkout's branch, from the watcher's API", %{session: session} do
    session
    |> visit(url(:web))
    |> assert_has(Query.text("Example app"))
    |> assert_has(css(".badge select"))
  end

  feature "the Branches menu opens clawswap's page in an iframe", %{session: session} do
    session
    |> visit(url(:web))
    |> click(button("⎇ Branches ▾"))
    |> focus_frame(css("iframe[title=clawswap]"))
    |> assert_has(css("li.current"))
    |> focus_default_frame()
    |> click(button("Close"))
    |> assert_has(css(".branch-menu-panel[hidden]", visible: false))
  end

  # Two people at once, each in a Chrome of their own: what one does in the page stays in theirs.
  @sessions 2
  feature "two people open the app; one opens the menu", %{sessions: [alice, bob]} do
    alice |> visit(url(:web)) |> click(button("⎇ Branches ▾")) |> assert_has(css(".branch-menu-panel:not([hidden])"))
    bob |> visit(url(:web)) |> assert_has(css(".badge select")) |> refute_has(css(".branch-menu-panel"))
  end
end
