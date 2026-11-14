defmodule ClawswapWeb.ViewTest do
  use ExUnit.Case, async: true

  alias ClawswapWeb.{StreamDeck, View}

  @state %{
    project: "bmx",
    base: "claude-main",
    current: %{branch: "claude-main", sha: "1"},
    dirty: false,
    webhook: "off",
    webhookError: nil,
    error: nil,
    upstream: %{sha: "2", behind: 2},
    switch: nil,
    branches: [
      %{branch: "claude-main", short: "claude-main", sha: "2"},
      %{branch: "claude/a", short: "a", sha: "3", pr: %{number: 4, title: "Add A", draft: false, updatedAt: ""}},
      %{branch: "claude/b", short: "b", sha: "5", merged: true}
    ]
  }

  test "works out what each row shows" do
    view = View.page(@state)
    assert view.pull_label == "↓ Pull 2 new commits"
    assert view.pull_class == "behind"
    assert view.webhook =~ "clawswap smee"
    assert [main, a, b] = view.branches
    assert {main.class, main.status, main.mark} == {"behind", "New commits", "⎇"}
    assert {a.title, a.number, a.mark, a.mark_class, a.mark_title} == {"Add A", "#4", "●", "open", "Open PR #4, not merged yet"}
    assert {b.title, b.mark, b.mark_class, b.mark_title} == {"b", "✓", "merged", "Merged into claude-main"}
    # The checkout's row is marked even while it shows new commits, and the header names it.
    assert {main.row_class, a.row_class} == {"behind checkout", ""}
    assert view.on == "claude-main"
    assert View.page(%{@state | current: %{branch: "claude/a", sha: "3"}}).on == "Add A"
  end

  test "greys out Pull when the branch isn't on GitHub, and says up to date only when it is" do
    assert {View.page(@state).pull_label, View.page(@state).pull_class} == {"↓ Pull 2 new commits", "behind"}
    up = View.page(%{@state | upstream: %{sha: "1", behind: 0}})
    assert {up.pull_label, up.pull_class} == {"↓ Pull (up to date)", ""}
    none = View.page(%{@state | upstream: nil})
    assert {none.pull_label, none.pull_class, none.pull_title} == {"Pull (not on GitHub)", "none", "claude-main isn't on GitHub, so there's nothing to pull"}
  end

  test "an unchecked webhook says where it listens, and isn't shown as a fault" do
    view = View.page(%{@state | webhook: "unchecked", webhookError: "no delivery yet on https://smee.io/x (no GitHub token to check it with)"})
    assert view.webhook == "webhook listening: no delivery yet on https://smee.io/x (no GitHub token to check it with)"
    assert view.webhook_class == "unchecked"
    assert View.page(%{@state | webhook: "connected"}).webhook_class == "ok"
  end

  test "follows a switch" do
    view = View.page(%{@state | switch: %{target: "claude/a", pull: false, phase: "running", step: "npm install", error: nil}})
    assert view.busy
    assert Enum.at(view.branches, 1).status == "npm install"
    failed = View.page(%{@state | switch: %{target: "claude/a", pull: false, phase: "failed", step: nil, error: "Uncommitted changes"}})
    assert failed.error == "Couldn't switch to claude/a: Uncommitted changes"
    assert Enum.at(failed.branches, 1).class == "failed"
    assert view.switched == nil and failed.switched == nil
    # A failed pull says it was a pull.
    pull = View.page(%{@state | switch: %{target: "claude-main", pull: true, phase: "failed", step: nil, error: "claude-main isn't on GitHub"}})
    assert pull.error == "Pull failed: claude-main isn't on GitHub"
    assert hd(pull.branches).status == "Pull failed"
    # A finished one says so, for the app framing the page.
    done = View.page(%{@state | switch: %{target: "claude/a", pull: false, phase: "done", step: nil, error: nil, doneAt: 7}})
    assert done.switched == %{branch: "claude/a", at: 7}
  end

  test "draws the OpenDeck plugin's key images for a deck the page drives" do
    keys = View.keys(@state)
    assert Enum.map(keys.branches, & &1.branch) == ["claude-main", "claude/a", "claude/b"]
    [main, a, _] = Enum.map(keys.branches, &URI.decode(&1.image))
    assert main =~ "New commits"
    assert a =~ "#4" and a =~ "Add A"
    assert URI.decode(keys.pull) =~ "2 new commits"
  end

  test "lays the branches out on a deck's keys, with the walkthrough and Pull on the last two" do
    keys = %{branches: Enum.map(1..20, &%{branch: "b#{&1}", image: "i#{&1}"}), walk: %{name: "login", image: "walk"}, pull: "pull"}
    images = StreamDeck.key_images(keys, 15)
    assert length(images) == 15
    assert {hd(images), Enum.at(images, 12), Enum.at(images, 13), List.last(images)} == {"i1", "i13", "walk", "pull"}
    assert StreamDeck.key_images(%{keys | branches: Enum.take(keys.branches, 2)}, 15) == ["i1", "i2"] ++ List.duplicate(nil, 11) ++ ["walk", "pull"]
    assert StreamDeck.key_command(keys, 15, 0) == {:switch, "b1"}
    assert StreamDeck.key_command(keys, 15, 13) == {:walk, "login"}
    assert StreamDeck.key_command(%{keys | walk: %{name: nil, image: "none"}}, 15, 13) == nil
    assert StreamDeck.key_command(keys, 15, 14) == :pull
    assert StreamDeck.key_command(%{keys | branches: []}, 15, 3) == nil
    assert StreamDeck.key_images(nil, 3) == [nil, nil, nil]
  end

  test "keeps a key for the next project when the keys follow the selected one" do
    keys = %{branches: Enum.map(1..20, &%{branch: "b#{&1}", image: "i#{&1}"}), walk: %{name: "login", image: "walk"}, pull: "pull", project: "proj"}
    images = StreamDeck.key_images(keys, 15)
    assert {Enum.at(images, 11), Enum.at(images, 12), Enum.at(images, 13), List.last(images)} == {"i12", "proj", "walk", "pull"}
    assert StreamDeck.key_command(keys, 15, 12) == :next_project
    assert StreamDeck.key_command(keys, 15, 11) == {:switch, "b12"}
  end

  test "says why the branch list is empty, only when it is" do
    assert View.page(%{@state | branches: []} |> Map.put(:empty, "No branches to list: x")).empty == "No branches to list: x"
    assert View.page(Map.put(@state, :empty, "stale")).empty == nil
  end
end
