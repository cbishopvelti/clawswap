defmodule Clawswap.ConfigFormTest do
  use ExUnit.Case, async: true

  alias Clawswap.Config
  alias Clawswap.Config.Form

  setup do
    root = Path.join(System.tmp_dir!(), "clawswap-form-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp project(root, file), do: %{root: root, file: file}

  defp write(root, file, text) do
    File.write!(Path.join(root, file), text)
    project(root, file)
  end

  # What the page sends: the loaded form, changed.
  defp save(project, form), do: Form.save(project, Map.take(form, [:values, :code, :rows]))

  defp read(project), do: File.read!(Form.path(project))

  defp row_id(form, section, orig), do: Enum.find(form.rows[section], &(&1.orig == orig)).id

  test "saving an unchanged form leaves the file alone", %{root: root} do
    p = write(root, "clawswap.exs", File.read!(Path.expand("../examples/bmx.exs", __DIR__)))
    {:ok, form} = Form.load(p)
    assert form.format == "exs"
    assert form.values["name"] == "bmx"
    assert form.values["servers.#{row_id(form, "servers", "phx")}.match"] == "/phx\\.server/"
    assert form.values["steps.#{row_id(form, "steps", "0")}.when"] == "/^docker-compose\\.ya?ml$/\nbeat-tracker/"
    assert {:ok, :unchanged} = save(p, form)
  end

  test "changes only what changed in a clawswap.exs, keeping its comments and code", %{root: root} do
    p =
      write(root, "clawswap.exs", """
      # My project
      [
        # the servers
        servers: [
          api: [command: "iex -S mix phx.server", cwd: "api", port: 4000],
          # the frontend
          web: [command: "npm run dev", cwd: "web"]
        ],
        steps: [
          # deps first
          [name: "deps", label: "deps", when: ~r/mix\\.(exs|lock)$/i, run: "mix deps.get"]
        ],
        short_name: &String.replace_prefix(&1, "feature/", "")
      ]
      """)

    {:ok, form} = Form.load(p)
    web = row_id(form, "servers", "web")
    step = row_id(form, "steps", "0")
    # A Regex with options and a function are shown as Elixir.
    assert form.code["steps.#{step}.when"]
    assert form.values["steps.#{step}.when"] == ~S"~r/mix\.(exs|lock)$/i"
    assert form.code["short_name"]

    values =
      form.values
      |> Map.put("servers.#{web}.port", "5173")
      |> Map.put("port", "8800")
      |> Map.put("steps.r9.label", "npm install")
      |> Map.put("steps.r9.when", "web/package.json\n/lock/")
      |> Map.put("steps.r9.run", "npm install")
      |> Map.put("steps.r9.cwd", "web")

    rows = Map.update!(form.rows, "steps", &(&1 ++ [%{id: "r9", orig: nil}]))
    assert {:ok, :saved} = save(p, %{form | values: values, rows: rows})

    text = read(p)
    assert text =~ "# My project"
    assert text =~ "# the frontend"
    assert text =~ "# deps first"
    assert text =~ ~S"when: ~r/mix\.(exs|lock)$/i"
    assert text =~ ~S|short_name: &String.replace_prefix(&1, "feature/", "")|
    assert text =~ ~S|web: [command: "npm run dev", cwd: "web", port: 5173]|
    assert text =~ ~S|name: "deps"|
    assert text =~ ~S|[label: "npm install", when: ["web/package.json", ~r/lock/], run: "npm install", cwd: "web"]|
    assert text =~ "port: 8800"

    {config, _} = Code.eval_string(text)
    assert config[:port] == 8800
    assert config[:servers][:web][:port] == 5173
    assert config[:servers][:api] == [command: "iex -S mix phx.server", cwd: "api", port: 4000]
  end

  test "renames, removes and reorders rows", %{root: root} do
    p = write(root, "clawswap.exs", ~s([servers: [a: [command: "x"], b: [command: "y"]], panes: [logs: [command: "tail -f log"]]]\n))
    {:ok, form} = Form.load(p)
    a = row_id(form, "servers", "a")
    b = row_id(form, "servers", "b")
    values = Map.put(form.values, "servers.#{a}._name", "first")
    rows = %{form.rows | "servers" => [Enum.find(form.rows["servers"], &(&1.id == b)), Enum.find(form.rows["servers"], &(&1.id == a))], "panes" => []}
    assert {:ok, :saved} = save(p, %{form | values: values, rows: rows})
    {config, _} = Code.eval_string(read(p))
    assert config == [servers: [b: [command: "y"], first: [command: "x"]]]
  end

  test "says what's wrong instead of saving a config that won't load", %{root: root} do
    p = write(root, "clawswap.exs", ~s([servers: [a: [command: "x"]]]\n))
    {:ok, form} = Form.load(p)
    a = row_id(form, "servers", "a")

    assert {:error, "Port: \"abc\" isn't a number"} = save(p, %{form | values: Map.put(form.values, "port", "abc")})
    assert {:error, "Server a has no command"} = save(p, %{form | values: Map.put(form.values, "servers.#{a}.command", "")})
    assert {:error, "Servers 1 needs a name"} = save(p, %{form | values: Map.put(form.values, "servers.#{a}._name", "")})
    assert {:error, "Short name for a branch: " <> _} = save(p, %{form | values: Map.put(form.values, "short_name", "fn x ->")})
    assert read(p) == ~s([servers: [a: [command: "x"]]]\n)
  end

  test "edits a clawswap.yml, writing regexes and Elixir back as strings", %{root: root} do
    p =
      write(root, "clawswap.yml", """
      name: shop
      short_name: 'fn b -> String.upcase(b) end'
      servers:
        web: {command: npm run dev, port: 5173, match: '/vite/'}
      steps:
        - {label: deps, when: ['&String.ends_with?(&1, ".lock")', mix.exs], run: [mix, deps.get]}
      """)

    {:ok, form} = Form.load(p)
    assert form.format == "yaml"
    web = row_id(form, "servers", "web")
    step = row_id(form, "steps", "0")
    assert form.values["short_name"] == "fn b -> String.upcase(b) end"
    assert form.values["servers.#{web}.match"] == "/vite/"
    assert form.values["steps.#{step}.when"] == "&String.ends_with?(&1, \".lock\")\nmix.exs"
    assert form.code["steps.#{step}.run"]
    assert {:ok, :unchanged} = save(p, form)

    assert {:ok, :saved} = save(p, %{form | values: Map.put(form.values, "base", "develop")})

    assert read(p) == """
           name: shop
           short_name: 'fn b -> String.upcase(b) end'
           servers:
             web:
               command: npm run dev
               port: 5173
               match: '/vite/'
           steps:
             - label: deps
               when: ['&String.ends_with?(&1, ".lock")', mix.exs]
               run: [mix, deps.get]
           base: develop
           """

    {:ok, config} = Config.read(Form.path(p))
    assert config[:short_name].("x") == "X"
    assert config[:servers][:web][:match].source == "vite"
  end
end
