defmodule Clawswap.Run do
  @moduledoc """
  Running commands: quietly for answers (git, zellij), or with their output shown in the watcher's pane
  (the update steps).
  """

  @doc """
  Runs a command and returns `{:ok, stdout}`, or `{:error, message}` with stderr's last line when it fails.
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

        {:error, first_present([last_line(stderr), last_line(out), "#{cmd} #{Enum.join(args, " ")} exited with #{code}"])}
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
  Runs a command with its output passed through to ours (each line prefixed), keeping the last lines for
  the error. Returns `:ok` or `{:error, message}`.
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
        cd: opts[:cwd] || File.cwd!()
      ])

    stream_loop(port, prefix, write, "", true)
  end

  defp stream_loop(port, prefix, write, tail, line_start?) do
    receive do
      {^port, {:data, text}} ->
        write.(prefixed(text, prefix, line_start?))
        stream_loop(port, prefix, write, String.slice(tail <> text, -2000, 2000), String.ends_with?(text, "\n"))

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        {:error, first_present([last_line(tail), "exited with #{code}"])}
    end
  end

  defp prefixed(text, "", _line_start?), do: text

  defp prefixed(text, prefix, line_start?) do
    body = String.replace(text, ~r/\n(?=.)/, "\n" <> prefix)
    if line_start?, do: prefix <> body, else: body
  end

  @doc "The last non-empty line of `text`, without colour codes."
  def last_line(text) do
    text
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> Kernel.||("")
  end

  defp first_present(list), do: Enum.find(list, &(&1 != "")) || ""
end
