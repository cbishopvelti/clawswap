defmodule Clawswap.StarterTest do
  use ExUnit.Case

  alias Clawswap.{Config, Starter}

  setup do
    root = Path.join(System.tmp_dir!(), "clawswap-starter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # The starter as clawswap would load it.
  defp load(root) do
    {config, _} = Code.eval_string(Starter.config(root))
    Config.normalise(config, root: root)
  end

  test "runs mix phx.server for a Phoenix app, with migrations when it has them", %{root: root} do
    File.write!("#{root}/mix.exs", ~s(defp deps, do: [{:phoenix, "~> 1.8"}, {:ecto_sql, "~> 3.0"}]))
    File.mkdir_p!("#{root}/priv/repo/migrations")
    assert Starter.detect(root) == :phoenix
    p = load(root)
    assert p.servers["web"].command == "mix phx.server"
    assert p.servers["web"].port == 4000
    assert Enum.map(p.steps, & &1.label) == ["mix deps.get", "mix ecto.migrate"]
  end

  test "runs no server for another Mix project", %{root: root} do
    File.write!("#{root}/mix.exs", ~s(defp deps, do: [{:jason, "~> 1.4"}]))
    assert Starter.detect(root) == :mix
    p = load(root)
    assert p.server_names == []
    assert Enum.map(p.steps, & &1.label) == ["mix deps.get"]
  end

  test "runs the dev script for a Node project, with its package manager and Vite's port", %{root: root} do
    File.write!("#{root}/package.json", ~s({"scripts": {"dev": "vite"}, "devDependencies": {"vite": "^7.0.0"}}))
    File.write!("#{root}/pnpm-lock.yaml", "")
    assert Starter.detect(root) == {:node, "pnpm", 5173}
    p = load(root)
    assert p.servers["web"].command == "pnpm run dev"
    assert p.servers["web"].port == 5173
    assert [%{label: "pnpm install"} = step] = p.steps
    assert step.test.("pnpm-lock.yaml")
  end

  test "leaves the servers to you when it can't tell", %{root: root} do
    File.write!("#{root}/package.json", ~s({"scripts": {"build": "tsc"}}))
    assert Starter.detect(root) == :unknown
    p = load(root)
    assert p.server_names == []
    assert p.steps == []
  end
end
