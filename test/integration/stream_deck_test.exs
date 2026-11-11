defmodule Clawswap.Integration.StreamDeckTest do
  # The page driving a Stream Deck over WebHID, with a stand-in deck in place of navigator.hid.
  use ExUnit.Case, async: false

  import Clawswap.Walkthrough.Script
  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 300_000

  # A Stream Deck MK.2 (15 keys) that records the images sent to it and can press its keys. Once chosen,
  # Chrome lets the page have it again without asking (getDevices), as a real one.
  @fake_deck """
  (() => {
    const reports = [];
    const device = new EventTarget();
    let granted = false;
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
    window.fakeDeck = {reports, press: (key) => { report([key]); report([]); }, down: (key) => report([key]), up: () => report([])};
    const hid = new EventTarget();
    hid.getDevices = async () => (granted ? [device] : []);
    hid.requestDevice = async () => { granted = true; return [device]; };
    Object.defineProperty(Navigator.prototype, "hid", {get: () => hid, configurable: true});
  })();
  """

  setup do
    Integration.compile!()
    project = Integration.up!(Integration.project!(), :tmux)
    on_exit(fn -> Integration.down!(project) end)
    Integration.browser!(project)
    %{project: project}
  end

  test "Connect Stream Deck draws the keys, and a key press switches" do
    connect_deck()

    say "Each key gets an image: the branches, then Pull on the last one"
    assert keys_drawn() == Enum.to_list(0..14)

    say "Pressing claude/new-heading's key switches to it"
    {:ok, state} = Integration.state()
    key = Enum.find_index(state["branches"], &(&1["branch"] == "claude/new-heading"))
    js("fakeDeck.press(arguments[0])", [key])
    Integration.wait_for_branch("claude/new-heading")
    see css("li.current", text: "new-heading"), timeout: 20_000
  end

  test "A key shows it's pressed at once, drawn by the page, then what the server says again" do
    connect_deck()
    keys_drawn()
    {:ok, state} = Integration.state()
    key = Enum.find_index(state["branches"], &(&1["branch"] == "claude/new-heading"))
    images = fn -> js("return fakeDeck.reports.filter(r => r.last && r.key === arguments[0]).length", [key]) end
    before = images.()

    say "Pressing a key outlines it, and holding it on says it's opening the branch's Claude Code thread"
    js("fakeDeck.down(arguments[0])", [key])
    wait_until(fn -> images.() >= before + 2 end, timeout: 3_000, message: "The held key wasn't redrawn twice")
    js("fakeDeck.up()")

    say "There's no thread for this branch: the page says so, and the key shows what it did before"
    see css(".deck-message", text: "No Claude Code thread")
    # The server's image for the key never changed, so only the mark running out redraws it.
    wait_until(fn -> images.() >= before + 3 end, timeout: 8_000, message: "The key wasn't put back")
  end

  test "When clawswap up starts the daemon again, the deck catches up at once", %{project: project} do
    connect_deck()
    keys_drawn()
    sent = js("return fakeDeck.reports.length")

    say "The daemon stops, and the checkout moves to another branch meanwhile"
    Integration.stop!(project)
    {_, 0} = System.cmd("git", ["checkout", "-q", "claude/new-heading"], cd: project.work, stderr_to_stdout: true)

    say "clawswap up starts it again: the open page's deck shows the new branch without waiting for its next beat"
    Integration.up!(project, :tmux, "claude/new-heading")
    # The page reconnects within Hologram's reconnect delay (5 s at most); the deck's own beat (20 s) is
    # what it used to wait for.
    wait_until(fn -> js("return fakeDeck.reports.length") > sent end, timeout: 10_000, message: "The deck wasn't redrawn")
  end

  # Connects the stand-in deck from the project's page.
  defp connect_deck do
    before_load(@fake_deck)

    say "Connect a (stand-in) Stream Deck from the page"
    visit url(:clawswap)
    # A click before the page's client is up does nothing, so wait for it (its link to the daemon is up),
    # and click again if the first was lost anyway.
    wait_until(fn -> js("return window.Hologram?.['sseConnected?'] === true") end, message: "The page didn't connect to the daemon")

    click_connect(3)
  end

  defp click_connect(tries) do
    if js("return !document.querySelector('.deck-on')"), do: click(button("Connect Stream Deck"))
    see css(".deck-on", text: "Stream Deck MK.2"), timeout: 8_000
  rescue
    error -> if tries > 1, do: click_connect(tries - 1), else: reraise(error, __STACKTRACE__)
  end

  # Waits until every key has had an image, and gives their numbers.
  defp keys_drawn do
    wait_until(fn ->
      (k = js("return [...new Set(fakeDeck.reports.filter(r => r.last).map(r => r.key))].sort((a, b) => a - b)")) |> length() == 15 && k
    end)
  end
end
