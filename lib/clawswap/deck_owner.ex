defmodule Clawswap.DeckOwner do
  @moduledoc """
  Which project's page drives the Stream Deck over WebHID, when several watchers run on one machine.
  Each project's page is its own origin, so pages can't see each other; their watchers share a file
  instead (`path/0`), naming the port and project of the watcher whose page has the deck. Pressing
  Connect on a page claims it (`claim/2`); the other watchers notice the file change (this GenServer
  looks every second) and tell their pages, which let the deck go and offer "Use here".

  An owner whose watcher has stopped (nothing listens on its port) counts as no owner, so a page can
  open the deck by itself again.

  Options: `port` and `name` (this watcher's), `on_change` (called when the owner changes), `path`.
  """

  use GenServer

  @poll_ms 1000

  @doc "The shared file: `$XDG_STATE_HOME/clawswap/stream-deck` (`~/.local/state` without it)."
  def path do
    state = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
    Path.join([state, "clawswap", "stream-deck"])
  end

  @doc "Makes the watcher on `port` (project `name`) the deck's owner."
  def claim(port, name, path \\ path()) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#{port}\t#{name}\n")
    :ok
  end

  @doc """
  The deck's owner as the watcher on `port` sees it: `%{owner: "mine"}`, `%{owner: "free"}` (no owner, or
  its watcher has stopped), or `%{owner: "other", name: project}`. Strings, as it goes to the page.
  """
  def status(port, path \\ path(), listening? \\ &listening?/1) do
    case read(path) do
      {^port, _} -> %{owner: "mine", name: nil}
      {other, name} -> if listening?.(other), do: %{owner: "other", name: name}, else: %{owner: "free", name: nil}
      nil -> %{owner: "free", name: nil}
    end
  end

  defp read(path) do
    with {:ok, text} <- File.read(path),
         [port, name] <- text |> String.trim_trailing("\n") |> String.split("\t", parts: 2),
         {port, ""} <- Integer.parse(port) do
      {port, name}
    else
      _ -> nil
    end
  end

  defp listening?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 200) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      {:error, _} -> false
    end
  end

  # `name: nil` starts one with no name (the tests do).
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    state = %{path: opts[:path] || path(), on_change: Keyword.fetch!(opts, :on_change), seen: nil}
    {:ok, %{state | seen: File.read(state.path)}, @poll_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    seen = File.read(state.path)
    if seen != state.seen, do: state.on_change.()
    {:noreply, %{state | seen: seen}, @poll_ms}
  end
end
