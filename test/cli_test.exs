defmodule Clawswap.CLITest do
  use ExUnit.Case, async: true

  alias Clawswap.CLI.{Completion, Forgive}

  @branches [
    %{"branch" => "main", "pr" => nil},
    %{"branch" => "feat/cli-forgiving", "pr" => %{"number" => 23}},
    %{"branch" => "fix/ports", "pr" => %{"number" => 21}},
    %{"branch" => "claude/project-thread-8d6g0u", "short" => "project-thread-8d6g0u", "pr" => nil},
    %{"branch" => "fix/port-docs", "pr" => nil}
  ]

  test "suggests the closest command to a typo" do
    names = Enum.map(Clawswap.CLI.commands(), &elem(&1, 0))
    assert Forgive.closest("swich", names) == "switch"
    assert Forgive.closest("stauts", names) == "status"
    assert Forgive.closest("comp", names) == "completion"
    assert Forgive.closest("xyz", names) == nil
  end

  test "finds the branch from its name, origin/name, PR number, short name or part of it" do
    assert Forgive.branch("main", @branches) == {:ok, "main"}
    assert Forgive.branch("origin/fix/ports", @branches) == {:ok, "fix/ports"}
    assert Forgive.branch("23", @branches) == {:ok, "feat/cli-forgiving"}
    assert Forgive.branch("#21", @branches) == {:ok, "fix/ports"}
    assert Forgive.branch("cli-forgiving", @branches) == {:ok, "feat/cli-forgiving"}
    assert Forgive.branch("CLI-FORGIV", @branches) == {:ok, "feat/cli-forgiving"}
    assert Forgive.branch("8d6g", @branches) == {:ok, "claude/project-thread-8d6g0u"}
    assert Forgive.branch("ports", @branches) == {:ok, "fix/ports"}
  end

  test "says when a part matches several, and suggests a near miss" do
    assert Forgive.branch("fix", @branches) == {:ambiguous, ["fix/ports", "fix/port-docs"]}
    assert Forgive.branch("cli-forgivng", @branches) == {:none, "feat/cli-forgiving"}
    assert Forgive.branch("99", @branches) == {:none, nil}
  end

  test "writes completion for bash, zsh and fish, with every command" do
    for shell <- Completion.shells() do
      script = Completion.script(shell, Clawswap.CLI.commands())
      for {name, _} <- Clawswap.CLI.commands(), do: assert(script =~ name)
      assert script =~ "refs/remotes/origin"
    end

    assert Completion.script("tcsh", []) == nil
  end
end
