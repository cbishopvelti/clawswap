defmodule Clawswap.CLI.Completion do
  @moduledoc """
  Shell completion scripts for bin/clawswap (`clawswap completion bash|zsh|fish`). They complete the
  commands, and for `switch` the branches on origin, read with git in the repo you're in so completing
  doesn't have to start mix.
  """

  @shells ~w(bash zsh fish)
  def shells, do: @shells

  # The branches on origin of the repo you're in, without origin/ and HEAD.
  @branches ~S"git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin 2>/dev/null | grep -v '^HEAD$'"

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
        update) COMPREPLY=($(compgen -W "--all" -- "$cur")) ;;
        walk) COMPREPLY=($(compgen -W "--headless" -- "$cur")) ;;
        completion) COMPREPLY=($(compgen -W "#{Enum.join(@shells, " ")}" -- "$cur")) ;;
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
        update) compadd -- --all ;;
        walk) compadd -- --headless ;;
        completion) compadd -- #{Enum.join(@shells, " ")} ;;
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
    complete -c clawswap -n '__fish_seen_subcommand_from update' -a --all
    complete -c clawswap -n '__fish_seen_subcommand_from walk' -a --headless
    complete -c clawswap -n '__fish_seen_subcommand_from completion' -a '#{Enum.join(@shells, " ")}'
    """
  end

  def script(_, _), do: nil

  # Summaries go inside single quotes (zsh's _describe also splits on a colon, so that is escaped too).
  defp single_quoted(text), do: String.replace(text, "'", "'\\''")
end
