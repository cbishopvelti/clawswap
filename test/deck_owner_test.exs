defmodule Clawswap.DeckOwnerTest do
  use ExUnit.Case, async: true

  alias Clawswap.DeckOwner

  setup do
    dir = Path.join(System.tmp_dir!(), "deck-owner-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    me = self()
    path = Path.join([dir, "clawswap", "stream-deck.json"])
    start = fn -> start_supervised!({DeckOwner, name: nil, path: path, on_change: fn -> send(me, :changed) end}, id: make_ref()) end
    %{path: path, start: start}
  end

  test "no tab has the deck until one claims it, and the last claim wins", %{start: start} do
    deck = start.()
    assert DeckOwner.status(deck) == %{tab: nil, keys: "follow"}
    :ok = DeckOwner.claim("tab-a", deck)
    assert_receive :changed
    assert DeckOwner.status(deck).tab == "tab-a"
    # Saying so again changes nothing.
    :ok = DeckOwner.claim("tab-a", deck)
    refute_receive :changed, 100
    :ok = DeckOwner.claim("tab-b", deck)
    assert_receive :changed
    assert DeckOwner.status(deck).tab == "tab-b"
  end

  test "pins the keys to a project, and remembers it", %{start: start, path: path} do
    deck = start.()
    :ok = DeckOwner.set_keys("shop", deck)
    assert_receive :changed
    assert DeckOwner.status(deck).keys == "shop"
    assert File.read!(path) =~ "shop"
    assert DeckOwner.status(start.()).keys == "shop"
  end

  test "an unreadable file means the keys follow the selected project", %{start: start, path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "nonsense")
    assert DeckOwner.status(start.()).keys == "follow"
  end
end
