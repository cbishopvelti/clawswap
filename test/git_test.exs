defmodule Clawswap.GitTest do
  use ExUnit.Case, async: true

  alias Clawswap.{Git, GitHub}

  @remote [
    %{branch: "claude/b", sha: "2", date: "2026-10-25"},
    %{branch: "claude-main", sha: "1", date: "2026-10-24"},
    %{branch: "claude/a", sha: "3", date: "2026-10-23"},
    %{branch: "claude/merged", sha: "4", date: "2026-10-20"}
  ]

  test "lists the base first, then open PRs' branches (or every branch) by newest commit" do
    names = &Enum.map(&1, fn b -> b.branch end)
    assert names.(Git.branch_list(remote: @remote, base: "claude-main", current: "claude-main")) == ["claude-main", "claude/b", "claude/a", "claude/merged"]

    pulls = %{
      "claude/b" => %{number: 2, title: "B", updated_at: "2026-10-24T00:00:00Z"},
      "claude/a" => %{number: 1, title: "A", updated_at: "2026-10-25T00:00:00Z"}
    }

    list = Git.branch_list(remote: @remote, pulls: pulls, base: "claude-main", current: "claude/merged", short_name: &String.replace_prefix(&1, "claude/", ""))
    assert names.(list) == ["claude-main", "claude/b", "claude/a", "claude/merged"]
    assert Enum.at(list, 2).pr.number == 1
    assert Enum.at(list, 2).short == "a"
  end

  test "marks branches already merged into the base" do
    remote = [%{branch: "main", sha: "1", date: ""}, %{branch: "done", sha: "2", date: ""}, %{branch: "new", sha: "3", date: ""}]
    list = Git.branch_list(remote: remote, base: "main", merged: MapSet.new(["main", "done"]))
    assert Enum.map(list, &{&1.branch, Map.get(&1, :merged, false)}) == [{"main", false}, {"done", true}, {"new", false}]
  end

  test "reads open PRs, and keeps the last list on a 304" do
    body =
      JSON.encode!([
        %{
          number: 7,
          title: "Seven",
          updated_at: "2026-10-26T00:00:00Z",
          draft: false,
          body: "_Requested by **C** · [project thread](https://claude.ai/code/project/chan_1?thread=cmsg_2)_\n\nhttps://claude.ai/code/session_3",
          head: %{ref: "claude/seven", repo: %{full_name: "me/app"}}
        },
        %{number: 8, title: "From a fork", updated_at: "2026-10-26T00:00:00Z", head: %{ref: "x", repo: %{full_name: "them/app"}}}
      ])

    {:ok, pulls, cache} = GitHub.read_pulls("me/app", "t", nil, fn _url, _headers -> {:ok, 200, [{"ETag", "\"abc\""}], body} end)
    assert Map.keys(pulls) == ["claude/seven"]
    assert pulls["claude/seven"].title == "Seven"
    # The thread its description links to.
    assert pulls["claude/seven"].claude == "https://claude.ai/code/project/chan_1?thread=cmsg_2"

    get = fn _url, headers ->
      assert {"if-none-match", "\"abc\""} in headers
      {:ok, 304, [], ""}
    end

    assert {:ok, ^pulls, ^cache} = GitHub.read_pulls("me/app", "t", cache, get)
    assert {:error, "GitHub answered 401", nil} = GitHub.read_pulls("me/app", "t", nil, fn _, _ -> {:ok, 401, [], ""} end)
  end

  test "finds the Claude Code link in a PR's description" do
    assert GitHub.claude_link("Done.\n\nhttps://claude.ai/code/session_01AbC") == "https://claude.ai/code/session_01AbC"
    assert GitHub.claude_link("[thread](https://claude.ai/code/project/chan_1?thread=cmsg_2) https://claude.ai/code/session_3") =~ "thread=cmsg_2"
    assert GitHub.claude_link("No link") == nil
    assert GitHub.claude_link(nil) == nil
  end
end
