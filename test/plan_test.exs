defmodule Clawswap.PlanTest do
  use ExUnit.Case, async: true

  alias Clawswap.{Config, Plan, TestRepo}

  setup_all do
    %{project: Config.normalise(TestRepo.bmx_config(), root: "/work/bmx")}
  end

  test "plans only the steps the changed files need, in the config's order", %{project: project} do
    names = fn changed -> project.steps |> Plan.steps(changed) |> Enum.map(& &1.name) end
    assert names.(["frontend/src/app.tsx"]) == []
    assert names.(["frontend/package-lock.json", "backend/mix.lock"]) == ["npm", "deps"]
    assert names.(["surrealdb/schema.surql", "beat-tracker/src/server.js"]) == ["docker", "schema", "access"]
    assert names.(["backend/priv/repo/migrations/1_x.exs"]) == ["migrate"]
    assert length(Plan.steps(project.steps, [], all: true)) == 6
  end

  test "runs a string through sh and a list as it is", %{project: project} do
    assert [%{name: "npm", label: "npm install", cmd: "sh", args: ["-c", "npm install"], cwd: "frontend"}] =
             Plan.steps(project.steps, ["frontend/package.json"])

    other = Config.normalise([steps: [[run: ["mix", "deps.get"], when: "mix.lock"]]], root: "/r")
    assert [%{name: "mix", label: "mix deps.get", cmd: "mix", args: ["deps.get"], cwd: "."}] = Plan.steps(other.steps, ["mix.lock"])
  end

  test "matches paths by Regex, exact path, folder or function" do
    m = Plan.matcher([~r/\.lock$/, "a/b.json", "dir/", &(&1 == "f")])
    assert Enum.map(["x.lock", "a/b.json", "a/b.jsonx", "dir/x/y", "dirx/y", "f"], m) == [true, true, false, true, false, true]
    refute Plan.matcher(nil).("anything")
  end

  test "says the notes for what changed", %{project: project} do
    assert Plan.notes(project.notes, ["opendeck-plugin/dev.bmx.deck.sdPlugin/bin/plugin.mjs"]) == ["The OpenDeck plugin changed: restart OpenDeck to load it"]
    assert Plan.notes(project.notes, ["frontend/x"]) == []
  end
end
