defmodule Clawswap.Integration.StreamDeckTest do
  # The page driving a Stream Deck over WebHID, with a stand-in deck in place of navigator.hid.
  use ExUnit.Case, async: false

  import Clawswap.Walkthrough.Script
  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 300_000

  # A Stream Deck MK.2 (15 keys) that records the images sent to it and can press its keys.
  @fake_deck """
  (() => {
    const reports = [];
    const device = new EventTarget();
    Object.assign(device, {
      vendorId: 0x0fd9, productId: 0x0080, productName: "Stream Deck MK.2", opened: false, collections: [],
      open: async () => { device.opened = true; },
      close: async () => { device.opened = false; },
      sendReport: async (id, data) => { reports.push({id, key: data[1], last: data[2]}); },
      sendFeatureReport: async () => {},
    });
    const report = (keys) => {
      const bytes = new Uint8Array(3 + 15);
      keys.forEach((k) => (bytes[3 + k] = 1));
      device.dispatchEvent(Object.assign(new Event("inputreport"), {reportId: 1, data: new DataView(bytes.buffer), device}));
    };
    window.fakeDeck = {reports, press: (key) => { report([key]); report([]); }};
    const hid = new EventTarget();
    hid.getDevices = async () => [];
    hid.requestDevice = async () => [device];
    Object.defineProperty(Navigator.prototype, "hid", {get: () => hid, configurable: true});
  })();
  """

  setup do
    Integration.compile!()
    project = Integration.up!(Integration.project!(), :tmux)
    on_exit(fn -> Integration.down!(project) end)
    Integration.browser!(project)
    :ok
  end

  test "Connect Stream Deck draws the keys, and a key press switches" do
    before_load(@fake_deck)

    say "Connect a (stand-in) Stream Deck from the page"
    visit url(:clawswap)
    click button("Connect Stream Deck")
    see css(".deck-on", text: "Stream Deck MK.2")

    say "Each key gets an image: the branches, then Pull on the last one"

    keys =
      wait_until(fn -> (k = js("return [...new Set(fakeDeck.reports.filter(r => r.last).map(r => r.key))].sort((a, b) => a - b)")) |> length() == 15 && k end)

    assert keys == Enum.to_list(0..14)

    say "Pressing claude/new-heading's key switches to it"
    {:ok, state} = Integration.state()
    key = Enum.find_index(state["branches"], &(&1["branch"] == "claude/new-heading"))
    js("fakeDeck.press(arguments[0])", [key])
    Integration.wait_for_branch("claude/new-heading")
    see css("li.current", text: "new-heading"), timeout: 20_000
  end
end
