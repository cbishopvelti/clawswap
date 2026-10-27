# A walkthrough: the Branches menu (clawswap's own page, in an iframe) and the badge built on its API.
# Run it with ▶ branches-menu on the watcher's page, or `clawswap walk branches-menu`.

say "The example app, with clawswap's badge in the top bar"
visit url(:web)
see "Example app"
see css(".badge select")

say "The Branches menu is clawswap's page in an iframe, laid out as a compact list"
click "Branches"

in_frame "iframe[title=clawswap]", fn ->
  see css("li.current")
  see "Current"
end

say "The ✕ closes it"
click button("Close")
see css(".branch-menu-panel[hidden]", visible: false)
