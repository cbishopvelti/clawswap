defmodule ClawswapWeb.ViewTest do
  use ExUnit.Case, async: true

  alias ClawswapWeb.View

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
  end

  test "follows a switch" do
    view = View.page(%{@state | switch: %{target: "claude/a", pull: false, phase: "running", step: "npm install", error: nil}})
    assert view.busy
    assert Enum.at(view.branches, 1).status == "npm install"
    failed = View.page(%{@state | switch: %{target: "claude/a", pull: false, phase: "failed", step: nil, error: "Uncommitted changes"}})
    assert failed.error == "claude/a: Uncommitted changes"
    assert Enum.at(failed.branches, 1).class == "failed"
  end
end
