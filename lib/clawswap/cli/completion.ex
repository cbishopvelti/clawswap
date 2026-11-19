defmodule Clawswap.CLI.Completion do
  @moduledoc """
  Shell completion scripts for bin/clawswap (`clawswap completion bash|zsh|fish`). They complete the
  commands, for `switch` the branches on origin, read with git in the repo you're in so completing
  doesn't have to start mix, and for `up` the override configs (clawswap.<name>.yml) in the folder you're in.

  `clawswap completion install` saves the script where the shell finds it and adds what the shell's startup
  file needs to find it (zsh's $fpath line, before compinit), and `clawswap reload` writes the saved ones
  again, so a new command completes once clawswap has reloaded.
  """

  @shells ~w(bash zsh fish)
  def shells, do: @shells

  # The branches on origin of the repo you're in, without origin/ and HEAD.
  @branches ~S"git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin 2>/dev/null | grep -v '^HEAD$'"

  # The override configs' names in the folder you're in: clawswap.<name>.exs, .yml or .yaml.
  @overrides ~S"find . -maxdepth 1 -name 'clawswap.*' 2>/dev/null | sed -nE 's#^\./clawswap\.(.+)\.(exs|yml|yaml)$#\1#p'"

  @doc "The script for `shell`, completing `commands` (`{name, summary}`), or nil for a shell it doesn't know."
  def script(shell, commands)

  def script("bash", commands) do
    names = Enum.map_join(commands, " ", &elem(&1, 0))

    """
    # clawswap completion for bash: source this from ~/.bashrc, or save it as
    # ~/.local/share/bash-completion/completions/clawswap
    _clawswap() {
      local cur=${COMP_WORDS[COMP_CWORD]}
      if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "#{names}" -- "$cur"))
        return
      fi
      case "${COMP_WORDS[1]}" in
        switch) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "$(#{@branches})" -- "$cur")) ;;
        up|watch) COMPREPLY=($(compgen -W "$(#{@overrides})" -- "$cur")) ;;
        daemon) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "stop" -- "$cur")); [ "$COMP_CWORD" -eq 3 ] && COMPREPLY=($(compgen -W "--all" -- "$cur")) ;;
        #{flag_cases(commands, ~S|COMPREPLY=($(compgen -W "|, ~S|" -- "$cur"))|)}
        completion) COMPREPLY=($(compgen -W "install #{Enum.join(@shells, " ")}" -- "$cur")) ;;
        help) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "#{names}" -- "$cur")) ;;
      esac
    }
    complete -F _clawswap clawswap
    """
  end

  def script("zsh", commands) do
    described = Enum.map_join(commands, "\n", fn {name, summary} -> "    '#{name}:#{summary |> single_quoted() |> String.replace(":", "\\:")}'" end)

    """
    #compdef clawswap
    # clawswap completion for zsh: save it as _clawswap in a folder on your $fpath, or source it from
    # ~/.zshrc after compinit
    _clawswap() {
      local -a commands
      commands=(
    #{described}
      )
      if (( CURRENT == 2 )); then
        _describe command commands
        return
      fi
      case $words[2] in
        switch) (( CURRENT == 3 )) && compadd -- ${(f)"$(#{@branches})"} ;;
        up|watch) compadd -- ${(f)"$(#{@overrides})"} ;;
        daemon) (( CURRENT == 3 )) && compadd -- stop; (( CURRENT == 4 )) && compadd -- --all ;;
        #{flag_cases(commands, "compadd -- ", "")}
        completion) compadd -- install #{Enum.join(@shells, " ")} ;;
        help) (( CURRENT == 3 )) && _describe command commands ;;
      esac
    }
    if [ "$funcstack[1]" = "_clawswap" ]; then _clawswap "$@"; else compdef _clawswap clawswap; fi
    """
  end

  def script("fish", commands) do
    subcommands =
      Enum.map_join(commands, "\n", fn {name, summary} ->
        "complete -c clawswap -n __fish_use_subcommand -a #{name} -d '#{single_quoted(summary)}'"
      end)

    """
    # clawswap completion for fish: save it as ~/.config/fish/completions/clawswap.fish
    complete -c clawswap -f
    #{subcommands}
    complete -c clawswap -n '__fish_seen_subcommand_from switch' -a '(#{String.replace(@branches, "'", "\\'")})'
    complete -c clawswap -n '__fish_seen_subcommand_from up watch' -a '(#{String.replace(@overrides, "'", "\\'")})'
    complete -c clawswap -n '__fish_seen_subcommand_from daemon; and not __fish_seen_subcommand_from stop' -a stop
    #{for {name, _} <- commands, (flags = Clawswap.CLI.flags(name)) != [], do: "complete -c clawswap -n '__fish_seen_subcommand_from #{name}' -a '#{Enum.join(flags, " ")}'\n"}\
    complete -c clawswap -n '__fish_seen_subcommand_from completion' -a 'install #{Enum.join(@shells, " ")}'
    complete -c clawswap -n '__fish_seen_subcommand_from help' -a '#{Enum.map_join(commands, " ", &elem(&1, 0))}'
    """
  end

  def script(_, _), do: nil

  # A shell `case` arm per command with options (Clawswap.CLI.flags/1), completing them.
  defp flag_cases(commands, before, after_) do
    Enum.map_join(
      for({name, _} <- commands, (flags = Clawswap.CLI.flags(name)) != [], do: {name, flags}),
      "\n    ",
      fn {name, flags} -> "#{name}) #{before}#{Enum.join(flags, " ")}#{after_} ;;" end
    )
  end

  @doc """
  Where `shell` loads completion from by itself, for the user `env` (a map of environment variables)
  describes: bash-completion's per-user folder, a folder for zsh's $fpath, fish's completions folder.
  """
  def path(shell, env \\ System.get_env())

  def path("bash", env), do: Path.join([data_home(env), "bash-completion", "completions", "clawswap"])
  def path("zsh", env), do: Path.join([home(env), ".zfunc", "_clawswap"])
  def path("fish", env), do: Path.join([config_home(env), "fish", "completions", "clawswap.fish"])

  @doc "The shell `env`'s $SHELL names, when it's one this completes for."
  def login_shell(env \\ System.get_env()) do
    shell = Path.basename(env["SHELL"] || "")
    if shell in @shells, do: shell
  end

  @doc """
  Saves `shell`'s script where it loads completion from, and returns `{path, changes}`: what it changed in
  the shell's startup file so a new terminal finds the script (nothing when that's set up already).
  """
  def install(shell, commands, env \\ System.get_env()) do
    path = write(shell, commands, env)
    {path, set_up(shell, path, env)}
  end

  @doc """
  Writes the scripts that are installed again (with `commands` as they are now), making sure each shell's
  startup file still finds them, and returns `[{path, changes}]`.
  """
  def refresh(commands, env \\ System.get_env()) do
    for shell <- @shells, File.exists?(path(shell, env)) do
      path = write(shell, commands, env)
      {path, set_up(shell, path, env)}
    end
  end

  @doc """
  What to run so the shell you're in picks up `shell`'s completion: a new shell in its place (sourcing the
  startup file again doesn't reload zsh's completion, which compinit has set up already).
  """
  def restart_hint(shell),
    do: "Run this (or open a new terminal) for Tab to complete clawswap's commands:\n\n    exec #{shell}\n"

  @doc "The shell whose completion `path` is (one `path/2` gives)."
  def shell_of(path) do
    cond do
      String.ends_with?(path, ".fish") -> "fish"
      Path.basename(path) == "_clawswap" -> "zsh"
      true -> "bash"
    end
  end

  defp write(shell, commands, env) do
    path = path(shell, env)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, script(shell, commands))
    path
  end

  # Marks the lines clawswap adds to a startup file, so it can tell they're there.
  @marker "# Tab completion for clawswap (added by clawswap completion install)"

  @bash_completion ~w(/usr/share/bash-completion/bash_completion /etc/bash_completion
    /opt/homebrew/etc/profile.d/bash_completion.sh /usr/local/etc/profile.d/bash_completion.sh)

  # bash reads that folder by itself only through the bash-completion package, so without it ~/.bashrc
  # sources the script.
  defp set_up("bash", path, env) do
    bashrc = Path.join(home(env), ".bashrc")
    text = read(bashrc)

    cond do
      Enum.any?(@bash_completion, &File.exists?/1) ->
        []

      text =~ @marker or text =~ ~r/^[^#\n]*(source|\.)\s+\S*bash-completion\/completions\/clawswap/m ->
        []

      true ->
        line = "source #{tilde(path, env)}"
        File.write!(bashrc, append(text, [@marker, line]))
        ["Added #{line} to #{bashrc} (bash-completion isn't installed, so bash doesn't read that folder by itself)"]
    end
  end

  # A line (not a comment) that runs compinit, or sources a framework that does.
  @runs_compinit ~r/^[^#]*(compinit|oh-my-zsh\.sh|zprezto|antigen|zinit|zplug|antidote|zimfw)/

  # zsh reads the script once its folder is on $fpath, which has to be set before compinit (or the
  # framework that runs it, like oh-my-zsh) runs. macOS's zsh doesn't run compinit unless .zshrc does.
  defp set_up("zsh", path, env) do
    zshrc = Path.join(env["ZDOTDIR"] || home(env), ".zshrc")
    text = read(zshrc)
    folder = tilde(Path.dirname(path), env)
    fpath = "fpath=(#{folder} $fpath)"

    if text =~ @marker or text =~ ~r/^[^#\n]*fpath[^#\n]*\.zfunc/m do
      []
    else
      lines = String.split(text, "\n")

      case Enum.find_index(lines, &(&1 =~ @runs_compinit)) do
        nil ->
          File.write!(zshrc, append(text, [@marker, fpath, "autoload -Uz compinit && compinit"]))
          ["Added #{fpath} and compinit to the end of #{zshrc} (it didn't run compinit, which zsh's completion needs)"]

        index ->
          {before, rest} = Enum.split(lines, index)
          File.write!(zshrc, Enum.join(before ++ [@marker, fpath] ++ rest, "\n"))
          ["Added #{fpath} to #{zshrc}, before: #{String.trim(hd(rest))}"]
      end
    end
  end

  defp set_up("fish", _path, _env), do: []

  defp read(file) do
    case File.read(file) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end

  # `text` with `lines` after it, a blank line between.
  defp append("", lines), do: Enum.join(lines, "\n") <> "\n"

  defp append(text, lines) do
    text = if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
    text <> "\n" <> Enum.join(lines, "\n") <> "\n"
  end

  # `path` starting with ~ when it's in the home folder, as people write it in a startup file.
  defp tilde(path, env) do
    case Path.relative_to(path, home(env)) do
      ^path -> path
      relative -> "~/" <> relative
    end
  end

  defp home(env), do: env["HOME"] || System.user_home!()
  defp data_home(env), do: env["XDG_DATA_HOME"] || Path.join([home(env), ".local", "share"])
  defp config_home(env), do: env["XDG_CONFIG_HOME"] || Path.join(home(env), ".config")

  # Summaries go inside single quotes (zsh's _describe also splits on a colon, so that is escaped too).
  defp single_quoted(text), do: String.replace(text, "'", "'\\''")
end
