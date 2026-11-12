defmodule Clawswap.CLI.Completion do
  @moduledoc """
  Shell completion scripts for bin/clawswap (`clawswap completion bash|zsh|fish`). They complete the
  commands, for `switch` the branches on origin, read with git in the repo you're in so completing
  doesn't have to start mix, and for `up` the override configs (clawswap.<name>.yml) in the folder you're in.

  `clawswap completion install` saves the script where the shell finds it, and `clawswap reload` writes the
  saved ones again, so a new command completes once clawswap has reloaded.
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
        update) COMPREPLY=($(compgen -W "--all" -- "$cur")) ;;
        walk) COMPREPLY=($(compgen -W "--headless" -- "$cur")) ;;
        test) COMPREPLY=($(compgen -W "--watch --headless --only --exclude --seed" -- "$cur")) ;;
        completion) COMPREPLY=($(compgen -W "install #{Enum.join(@shells, " ")}" -- "$cur")) ;;
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
        update) compadd -- --all ;;
        walk) compadd -- --headless ;;
        test) compadd -- --watch --headless --only --exclude --seed ;;
        completion) compadd -- install #{Enum.join(@shells, " ")} ;;
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
    complete -c clawswap -n '__fish_seen_subcommand_from update' -a --all
    complete -c clawswap -n '__fish_seen_subcommand_from walk' -a --headless
    complete -c clawswap -n '__fish_seen_subcommand_from test' -a '--watch --headless --only --exclude --seed'
    complete -c clawswap -n '__fish_seen_subcommand_from completion' -a 'install #{Enum.join(@shells, " ")}'
    """
  end

  def script(_, _), do: nil

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
  Saves `shell`'s script where it loads completion from, and returns `{path, notes}`: what else the shell
  needs, if anything, before Tab completes in a new terminal.
  """
  def install(shell, commands, env \\ System.get_env()) do
    path = write(shell, commands, env)
    {path, notes(shell, path, env)}
  end

  @doc "Writes the scripts that are installed again (with `commands` as they are now), and returns their paths."
  def refresh(commands, env \\ System.get_env()) do
    for shell <- @shells, File.exists?(path(shell, env)), do: write(shell, commands, env)
  end

  defp write(shell, commands, env) do
    path = path(shell, env)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, script(shell, commands))
    path
  end

  @bash_completion ~w(/usr/share/bash-completion/bash_completion /etc/bash_completion
    /opt/homebrew/etc/profile.d/bash_completion.sh /usr/local/etc/profile.d/bash_completion.sh)

  # bash reads that folder only through the bash-completion package; zsh only once the folder is on $fpath.
  defp notes("bash", path, _env) do
    if Enum.any?(@bash_completion, &File.exists?/1),
      do: [],
      else: ["bash-completion doesn't seem to be installed, so add this to ~/.bashrc: source #{path}"]
  end

  defp notes("zsh", path, env) do
    zshrc = Path.join(env["ZDOTDIR"] || home(env), ".zshrc")
    folder = Path.dirname(path)

    on_fpath? =
      case File.read(zshrc) do
        {:ok, text} -> text =~ ".zfunc"
        _ -> false
      end

    if on_fpath?,
      do: [],
      else: ["Add this to #{zshrc}, before compinit (or before oh-my-zsh is sourced): fpath=(#{folder} $fpath)"]
  end

  defp notes("fish", _path, _env), do: []

  defp home(env), do: env["HOME"] || System.user_home!()
  defp data_home(env), do: env["XDG_DATA_HOME"] || Path.join([home(env), ".local", "share"])
  defp config_home(env), do: env["XDG_CONFIG_HOME"] || Path.join(home(env), ".config")

  # Summaries go inside single quotes (zsh's _describe also splits on a colon, so that is escaped too).
  defp single_quoted(text), do: String.replace(text, "'", "'\\''")
end
