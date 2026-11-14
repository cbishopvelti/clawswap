defmodule Clawswap.Run do
  @moduledoc """
  Running commands: quietly for answers (git, zellij, tmux), or with their output shown in the watcher's pane
  (the update steps).
  """

  @doc """
  Runs a command and returns `{:ok, stdout}`, or `{:error, message}` with stderr's error lines when it
  fails (see `error_summary/1`).
  """
  def capture(cmd, args, opts \\ []) do
    err = Path.join(System.tmp_dir!(), "clawswap-#{System.unique_integer([:positive])}.err")

    try do
      # stderr goes to a file so it doesn't mix with the answer, and is there for the error.
      {out, code} =
        System.cmd("sh", ["-c", ~s(exec "$@" 2>"$CLAWSWAP_ERR" </dev/null), "sh", cmd | args],
          cd: opts[:cwd] || File.cwd!(),
          env: [{"CLAWSWAP_ERR", err} | opts[:env] || []]
        )

      if code == 0 do
        {:ok, out}
      else
        stderr =
          case File.read(err),
            do: (
              {:ok, text} -> text
              _ -> ""
            )

        {:error, first_present([error_summary(stderr), error_summary(out), "#{cmd} #{Enum.join(args, " ")} exited with #{code}"])}
      end
    after
      File.rm(err)
    end
  end

  @doc "Like `capture/3`, but raises on failure."
  def capture!(cmd, args, opts \\ []) do
    case capture(cmd, args, opts) do
      {:ok, out} -> out
      {:error, message} -> raise RuntimeError, message
    end
  end

  @doc """
  Runs a command with its output passed through to ours (each line prefixed), keeping the last of it for
  the error (see `error_summary/1`). Returns `:ok` or `{:error, message}`. `env` is `{name, value}` pairs (nil unsets one).
  """
  def stream(cmd, args, opts \\ []) do
    prefix = opts[:prefix] || ""
    write = opts[:write] || (&IO.write/1)

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", ~s(exec "$@" </dev/null), "sh", cmd | args],
        cd: opts[:cwd] || File.cwd!(),
        env: for({name, value} <- opts[:env] || [], do: {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)})
      ])

    stream_loop(port, prefix, write, "", true)
  end

  # Enough of the output to reach back past a long npm or compiler report to where the error starts.
  @tail_size 8000

  defp stream_loop(port, prefix, write, tail, line_start?) do
    receive do
      {^port, {:data, text}} ->
        write.(prefixed(text, prefix, line_start?))
        stream_loop(port, prefix, write, String.slice(tail <> text, -@tail_size, @tail_size), String.ends_with?(text, "\n"))

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        {:error, first_present([error_summary(tail), "exited with #{code}"])}
    end
  end

  defp prefixed(text, "", _line_start?), do: text

  defp prefixed(text, prefix, line_start?) do
    body = String.replace(text, ~r/\n(?=.)/, "\n" <> prefix)
    if line_start?, do: prefix <> body, else: body
  end

  # A line that starts an error report: "npm error ...", "error: ...", "fatal: ...", "TypeError: ...",
  # "** (Mix) ...", "E: ...".
  @error_line ~r/^(?:npm (?:ERR!|error)(?:\s|$)|yarn error\b|pnpm ERR|ERR!|\*\* \(|E: |(?:\S+: )?(?:fatal|error)\b|\w*(?:Error|Exception)\b)/i
  # Lines that say where to look rather than what went wrong.
  @noise ~r/complete log of this run|for a full report see|^\S*\/_logs\/|^code \S+$|^errno -?\d+$|^A complete log|^\d+$/i
  @max_error_lines 3
  @max_error_length 400

  @doc """
  What went wrong, from a failed command's output: its first few error lines (npm's "npm error" prefix and
  pointers to its log dropped) joined with " · ", or the last line when nothing looks like an error.
  """
  def error_summary(text) do
    lines = clean_lines(text)

    case lines
         |> Enum.filter(&Regex.match?(@error_line, &1))
         |> Enum.map(&strip_tool_prefix/1)
         |> Enum.reject(&(&1 == "" or Regex.match?(@noise, &1)))
         |> Enum.uniq() do
      [] ->
        last_line(text)

      errors ->
        errors |> Enum.take(@max_error_lines) |> Enum.join(" · ") |> String.slice(0, @max_error_length)
    end
  end

  @doc "The last non-empty line of `text`, without colour codes."
  def last_line(text), do: text |> clean_lines() |> List.last() |> Kernel.||("")

  defp clean_lines(text) do
    text
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.map(&(&1 |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]/, "") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_tool_prefix(line), do: line |> String.replace(~r/^(?:npm (?:ERR!|error)|yarn error|pnpm ERR!?|ERR!)\s*/i, "") |> String.trim()

  defp first_present(list), do: Enum.find(list, &(&1 != "")) || ""
end
