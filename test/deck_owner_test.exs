defmodule Clawswap.DeckOwnerTest do
  use ExUnit.Case, async: true

  alias Clawswap.DeckOwner

  setup do
    dir = Path.join(System.tmp_dir!(), "deck-owner-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join([dir, "clawswap", "stream-deck"])}
  end

  test "nobody has the deck until a page claims it", %{path: path} do
    assert DeckOwner.status(27390, path, fn _ -> true end) == %{owner: "free", name: nil}
    :ok = DeckOwner.claim(27390, "shop", path)
    assert DeckOwner.status(27390, path, fn _ -> true end) == %{owner: "mine", name: nil}
  end

  test "another project's watcher has it while it listens", %{path: path} do
    :ok = DeckOwner.claim(27400, "blog", path)
    assert DeckOwner.status(27390, path, fn 27400 -> true end) == %{owner: "other", name: "blog"}
    assert DeckOwner.status(27390, path, fn 27400 -> false end) == %{owner: "free", name: nil}
  end

  test "a claim takes it from the last owner", %{path: path} do
    :ok = DeckOwner.claim(27400, "blog", path)
    :ok = DeckOwner.claim(27390, "shop", path)
    assert DeckOwner.status(27400, path, fn _ -> true end) == %{owner: "other", name: "shop"}
  end

  test "an unreadable file means nobody", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "junk")
    assert DeckOwner.status(27390, path, fn _ -> true end) == %{owner: "free", name: nil}
  end

  test "tells the watcher when the owner changes", %{path: path} do
    test = self()
    start_supervised!({DeckOwner, name: nil, path: path, on_change: fn -> send(test, :changed) end})
    refute_receive :changed, 1200
    :ok = DeckOwner.claim(27400, "blog", path)
    assert_receive :changed, 2500
  end
end
