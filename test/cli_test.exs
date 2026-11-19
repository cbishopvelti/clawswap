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

  test "help groups every command once, everyday first" do
    sections = Clawswap.CLI.sections()
    assert Enum.map(sections, &elem(&1, 0)) |> Enum.map(&hd(String.split(&1))) == ["Everyday", "Setup", "Internal"]

    listed = for {_, rows} <- sections, {name, _, _} <- rows, do: name
    assert Enum.sort(listed) == Enum.sort(Enum.map(Clawswap.CLI.commands(), &elem(&1, 0)))

    names = fn heading -> for {^heading, rows} <- sections, {name, _, _} <- rows, do: name end
    assert "switch" in names.("Everyday")
    assert "completion" in names.("Setup")
    for name <- ~w(self-update self-pull pull-self), do: assert(name in names.("Setup"))
    assert "daemon" in names.("Internal (up and the session run these for you)")
  end

  test "shows one command's usage and options" do
    assert Clawswap.CLI.usage("switch") =~ "Usage: clawswap switch <branch>\n\nSwitch branch"
    refute Clawswap.CLI.usage("switch") =~ "Options:"

    test = Clawswap.CLI.usage("test")
    assert test =~ "Usage: clawswap test [path...]"
    assert test =~ ~r/Options:\n  --watch +Show Chrome/
    assert test =~ ~r/  --only <tag> +Run only/
    assert test =~ ~r/  --max-cases <n> +How many/
    assert Clawswap.CLI.usage("smee") =~ ~r/--new +Make a new/

    assert Clawswap.CLI.usage("nope") == nil
    for {name, _} <- Clawswap.CLI.commands(), do: assert(Clawswap.CLI.usage(name) =~ "clawswap #{name}")
  end

  test "reads every command's options with OptionParser, and turns down ones it doesn't take" do
    alias Clawswap.CLI
    assert CLI.parse("update", ["--all"]) == {:ok, [], [all: true]}
    assert CLI.parse("update", ["abc123"]) == {:ok, ["abc123"], []}
    assert CLI.parse("smee", ["--new"]) == {:ok, [], [new: true]}
    assert CLI.parse("walk", ["branches-menu", "--headless"]) == {:ok, ["branches-menu"], [headless: true]}
    assert CLI.parse("test", ["a_test.exs", "--max-cases", "2"]) == {:ok, ["a_test.exs"], [max_cases: 2]}

    assert CLI.parse("self-update", ["--no-reload"]) == {:ok, [], [reload: false]}
    assert {:error, _} = CLI.parse("self-pull", ["--reload"])

    assert {:error, message} = CLI.parse("walk", ["--headles"])
    assert message =~ "walk has no option --headles. Did you mean --headless?"
    assert {:error, message} = CLI.parse("update", ["--al"])
    assert message =~ "Did you mean --all?"
    assert {:error, message} = CLI.parse("test", ["--xyz"])
    assert message =~ "test has no option --xyz; it takes --watch"
    assert {:error, message} = CLI.parse("status", ["--verbose"])
    assert message =~ "status takes no options (got --verbose)"
    assert {:error, message} = CLI.parse("test", ["--seed", "abc"])
    assert message =~ "test --seed takes a number"
    assert {:error, message} = CLI.parse("switch", ["--headless", "main"])
    assert message =~ "switch takes no options"
    assert {:error, message} = CLI.parse("update", ["a", "b"])
    assert message =~ "update takes [rev], not a b"
  end

  test "completes each command's options" do
    for shell <- Completion.shells() do
      script = Completion.script(shell, Clawswap.CLI.commands())
      for flag <- ~w(--all --new --headless --max-cases), do: assert(script =~ flag)
    end
  end

  test "writes completion for bash, zsh and fish, with every command" do
    for shell <- Completion.shells() do
      script = Completion.script(shell, Clawswap.CLI.commands())
      for {name, _} <- Clawswap.CLI.commands(), do: assert(script =~ name)
      assert script =~ "refs/remotes/origin"
    end

    assert Completion.script("tcsh", []) == nil
  end

  @tag :tmp_dir
  test "installs completion where each shell looks, and refreshes the installed ones", %{tmp_dir: home} do
    env = %{"HOME" => home, "SHELL" => "/usr/bin/zsh"}
    assert Completion.login_shell(env) == "zsh"
    assert Completion.login_shell(%{"SHELL" => "/bin/tcsh"}) == nil

    {path, [change]} = Completion.install("zsh", [{"up", "Start"}], env)
    assert path == Path.join(home, ".zfunc/_clawswap")
    assert change =~ "fpath=(~/.zfunc $fpath) and compinit to the end"
    zshrc = File.read!(Path.join(home, ".zshrc"))
    assert zshrc =~ ~r/^fpath=\(~\/\.zfunc \$fpath\)\nautoload -Uz compinit && compinit\n$/m

    # Once it's there, installing again changes nothing.
    assert {^path, []} = Completion.install("zsh", [{"up", "Start"}], env)
    assert File.read!(Path.join(home, ".zshrc")) == zshrc

    {bash, bash_changes} = Completion.install("bash", [{"up", "Start"}], env)
    assert bash == Path.join(home, ".local/share/bash-completion/completions/clawswap")

    # Without the bash-completion package ~/.bashrc sources the script.
    if bash_changes != [] do
      assert File.read!(Path.join(home, ".bashrc")) =~ "\nsource ~/.local/share/bash-completion/completions/clawswap\n"
      assert {_, []} = Completion.install("bash", [{"up", "Start"}], env)
    end

    assert [{^bash, []}, {^path, []}] = Completion.refresh([{"up", "Start"}, {"reload", "Reload"}], env)
    assert File.read!(bash) =~ "up reload"
    assert File.read!(path) =~ "'reload:Reload'"
    refute File.exists?(Completion.path("fish", env))

    assert Completion.restart_hint("zsh") =~ "\n    exec zsh\n"
    assert Enum.map(Completion.shells(), &Completion.shell_of(Completion.path(&1, env))) == Completion.shells()
  end

  @tag :tmp_dir
  test "puts zsh's fpath line before compinit or the framework that runs it", %{tmp_dir: home} do
    env = %{"HOME" => home}
    zshrc = Path.join(home, ".zshrc")

    File.write!(zshrc, """
    # compinit is run by oh-my-zsh
    export ZSH="$HOME/.oh-my-zsh"
    plugins=(git)
    source $ZSH/oh-my-zsh.sh
    alias g=git
    """)

    assert {_, [change]} = Completion.install("zsh", [], env)
    assert change =~ "before: source $ZSH/oh-my-zsh.sh"

    assert File.read!(zshrc) =~
             "plugins=(git)\n# Tab completion for clawswap (added by clawswap completion install)\n" <>
               "fpath=(~/.zfunc $fpath)\nsource $ZSH/oh-my-zsh.sh\nalias g=git\n"

    File.write!(zshrc, "autoload -Uz compinit\ncompinit\n")
    assert {_, [_]} = Completion.install("zsh", [], env)
    assert File.read!(zshrc) =~ ~r/\Afpath=|\A# Tab completion/

    # An fpath line the person wrote counts; reload adds the line for a script installed before.
    File.write!(zshrc, "fpath+=~/.zfunc\ncompinit\n")
    assert {_, []} = Completion.install("zsh", [], env)
    File.write!(zshrc, "compinit\n")
    assert [{_, [_]}] = Completion.refresh([], env)
    assert File.read!(zshrc) =~ "fpath=(~/.zfunc $fpath)\ncompinit\n"

    # With ZDOTDIR, zsh reads .zshrc from there.
    zdotdir = Path.join(home, "zsh")
    File.mkdir_p!(zdotdir)
    assert {_, [_]} = Completion.install("zsh", [], Map.put(env, "ZDOTDIR", zdotdir))
    assert File.exists?(Path.join(zdotdir, ".zshrc"))
  end

  test "talks to this checkout's own project, and fails without a config rather than use the selected one" do
    %{dir: dir, work: work} = Clawswap.TestRepo.setup()

    try do
      assert {:error, "clawswap: no clawswap project here" <> message} = Clawswap.CLI.api_base(work)
      assert message =~ "No clawswap.exs"

      File.write!("#{work}/clawswap.exs", "[session: \"shop\", port: 27400, servers: [web: [command: \"x\"]]]")
      assert Clawswap.CLI.api_base(work) == {:ok, "http://127.0.0.1:27400/p/shop"}
    after
      File.rm_rf!(dir)
    end
  end
end
