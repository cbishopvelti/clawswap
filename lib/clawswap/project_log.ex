defmodule Clawswap.ProjectLog do
  @moduledoc """
  One project's log in the daemon: an IO device that is the group leader of the project's processes (its
  watcher and the tasks it starts), so whatever they print (`Clawswap.Watcher.log/1`, the update steps'
  output) lands here instead of in the daemon's terminal. It keeps the last lines for a pane that
  attaches late, sends each write to the attached panes (`clawswap watch`, through the API's /log), and
  copies it to the daemon's own output with the project's name in front.

  Options: `id` (the project's), `name` (to register it under), `echo` (where the copy goes: a function
  of the text, or nil for none).
  """

  use GenServer

  @keep_lines 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Sends `pid` what's been logged so far, as `{:clawswap_log, text}`, then each new write, until it exits or detaches."
  def attach(log, pid \\ self()), do: GenServer.call(log, {:attach, pid})

  def detach(log, pid \\ self()), do: GenServer.call(log, {:detach, pid})

  @doc "The lines kept, oldest first, as one string."
  def text(log), do: GenServer.call(log, :text)

  @doc "Runs `fun` with `log` as its process's group leader, so what it prints goes to the log (for tasks)."
  def wrap(fun, log \\ Process.group_leader()) do
    fn ->
      Process.group_leader(self(), log)
      fun.()
    end
  end

  @impl true
  def init(opts) do
    id = opts[:id]
    echo = Keyword.get(opts, :echo, fn text -> IO.write(Enum.map_join(String.split(text, ~r/(?<=\n)/, trim: true), &"[#{id}] #{&1}")) end)
    {:ok, %{lines: :queue.new(), count: 0, partial: "", watchers: %{}, echo: echo}}
  end

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    send(pid, {:clawswap_log, kept(state)})
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.watchers[pid], ref)}
  end

  def handle_call({:detach, pid}, _from, state), do: {:reply, :ok, forget(state, pid)}

  def handle_call(:text, _from, state), do: {:reply, kept(state), state}

  @impl true
  def handle_info({:io_request, from, reply_as, request}, state) do
    {reply, state} = io_request(request, state)
    send(from, {:io_reply, reply_as, reply})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, forget(state, pid)}

  def handle_info(_, state), do: {:noreply, state}

  defp forget(state, pid) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | watchers: watchers}
  end

  defp kept(state), do: Enum.join(:queue.to_list(state.lines)) <> state.partial

  # The IO protocol (https://www.erlang.org/doc/apps/stdlib/io_protocol.html): output only.
  defp io_request({:put_chars, encoding, chars}, state), do: put(chars_to_binary(chars, encoding), state)
  defp io_request({:put_chars, chars}, state), do: put(chars_to_binary(chars, :latin1), state)

  defp io_request({:put_chars, encoding, m, f, a}, state), do: io_request({:put_chars, encoding, apply(m, f, a)}, state)
  defp io_request({:put_chars, m, f, a}, state), do: io_request({:put_chars, :latin1, apply(m, f, a)}, state)

  defp io_request({:requests, requests}, state) do
    Enum.reduce_while(requests, {:ok, state}, fn request, {_, state} ->
      case io_request(request, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp io_request(:getopts, state), do: {[binary: true, encoding: :unicode], state}
  defp io_request({:getopts, _}, state), do: {[binary: true, encoding: :unicode], state}
  defp io_request({:setopts, _}, state), do: {:ok, state}
  defp io_request({:get_geometry, _}, state), do: {{:error, :enotsup}, state}
  defp io_request(_, state), do: {{:error, :request}, state}

  defp chars_to_binary(chars, :unicode), do: IO.chardata_to_string(chars)
  defp chars_to_binary(chars, _latin1), do: :erlang.iolist_to_binary(chars) |> :unicode.characters_to_binary(:latin1)

  defp put(text, state) do
    if state.echo, do: state.echo.(text)
    Enum.each(Map.keys(state.watchers), &send(&1, {:clawswap_log, text}))
    {:ok, keep(state, text)}
  end

  # Whole lines go in the queue (the last @keep_lines of them); the rest waits for its newline.
  defp keep(state, text) do
    [partial | lines] = String.split(state.partial <> text, ~r/(?<=\n)/) |> Enum.reverse()

    {queue, count} =
      lines
      |> Enum.reverse()
      |> Enum.reduce({state.lines, state.count}, fn line, {q, n} ->
        q = :queue.in(line, q)
        if n >= @keep_lines, do: {:queue.drop(q), n}, else: {q, n + 1}
      end)

    %{state | lines: queue, count: count, partial: partial}
  end
end
