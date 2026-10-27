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

  test "follows a switch" do
    view = View.page(%{@state | switch: %{target: "claude/a", pull: false, phase: "running", step: "npm install", error: nil}})
    assert view.busy
    assert Enum.at(view.branches, 1).status == "npm install"
    failed = View.page(%{@state | switch: %{target: "claude/a", pull: false, phase: "failed", step: nil, error: "Uncommitted changes"}})
    assert failed.error == "claude/a: Uncommitted changes"
    assert Enum.at(failed.branches, 1).class == "failed"
  end

  test "draws the OpenDeck plugin's key images for a deck the page drives" do
    keys = View.page(@state).keys
    assert Enum.map(keys.branches, & &1.branch) == ["claude-main", "claude/a", "claude/b"]
    [main, a, _] = Enum.map(keys.branches, &URI.decode(&1.image))
    assert main =~ "New commits"
    assert a =~ "#4" and a =~ "Add A"
    assert URI.decode(keys.pull) =~ "2 new commits"
  end

  test "lays the branches out on a deck's keys, with Pull on the last" do
    keys = %{branches: Enum.map(1..20, &%{branch: "b#{&1}", image: "i#{&1}"}), pull: "pull"}
    images = StreamDeck.key_images(keys, 15)
    assert length(images) == 15
    assert {hd(images), Enum.at(images, 13), List.last(images)} == {"i1", "i14", "pull"}
    assert StreamDeck.key_images(%{keys | branches: Enum.take(keys.branches, 2)}, 15) == ["i1", "i2"] ++ List.duplicate(nil, 12) ++ ["pull"]
    assert StreamDeck.key_command(keys, 15, 0) == {:switch, "b1"}
    assert StreamDeck.key_command(keys, 15, 14) == :pull
    assert StreamDeck.key_command(%{keys | branches: []}, 15, 3) == nil
  end
end
