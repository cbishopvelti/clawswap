defmodule Clawswap.DeckOwner do
  @moduledoc """
  The Stream Deck that clawswap's pages drive over WebHID: which page drives it, and which project its
  keys serve.

  Every project's page is on the daemon's one origin now, so any of them can open the deck; one browser
  tab has it at a time, the one where Connect (or "Use here") was last pressed (`claim/1`, by the tab's
  id). The others let it go and offer "Use here". The tab that has it says so again every so often, so a
  closed tab's claim runs out (`@stale_ms`) and the next page to load opens the deck by itself.

  The keys follow the selected project (`Clawswap.Projects.selected/0`, which changes with the tab you're
  on), with a key that selects the next one, or are pinned to one project (`set_keys/1`). That choice is
  kept in `path/0`, so it outlives the daemon.

  Options: `on_change` (called when the owner or the choice changes), `path`, `name`.
  """

  use GenServer

  @stale_ms 60_000

  @doc "Where the keys' choice is kept: `$XDG_STATE_HOME/clawswap/stream-deck.json` (`~/.local/state` without it)."
  def path do
    state = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
    Path.join([state, "clawswap", "stream-deck.json"])
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The tab `tab` has the deck now (or still has it)."
  def claim(tab, server \\ __MODULE__), do: GenServer.call(server, {:claim, tab})

  @doc """
  `%{tab, keys}`: the tab that has the deck (nil when none has said so lately), and what its keys serve,
  `"follow"` (the selected project) or a project's id (pinned to it).
  """
  def status(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{tab: nil, keys: "follow"}
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc ~s|Makes the keys follow the selected project ("follow"), or pins them to a project's id.|
  def set_keys(keys, server \\ __MODULE__) when is_binary(keys), do: GenServer.call(server, {:keys, keys})

  @impl true
  def init(opts) do
    path = opts[:path] || path()

    keys =
      with {:ok, text} <- File.read(path), {:ok, %{"keys" => keys}} when is_binary(keys) <- JSON.decode(text) do
        keys
      else
        _ -> "follow"
      end

    {:ok, %{path: path, on_change: Keyword.fetch!(opts, :on_change), tab: nil, at: 0, keys: keys}}
  end

  @impl true
  def handle_call({:claim, tab}, _from, state) do
    changed = tab != current_tab(state)
    state = %{state | tab: tab, at: now()}
    if changed, do: tell(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, %{tab: current_tab(state), keys: state.keys}, state}

  def handle_call({:keys, keys}, _from, state) do
    if keys != state.keys do
      File.mkdir_p!(Path.dirname(state.path))
      File.write!(state.path, JSON.encode!(%{keys: keys}) <> "\n")
      tell(state)
    end

    {:reply, :ok, %{state | keys: keys}}
  end

  # Not from here: on_change asks for the status.
  defp tell(state), do: Task.start(state.on_change)

  defp current_tab(state), do: if(now() - state.at < @stale_ms, do: state.tab)
  defp now, do: System.monotonic_time(:millisecond)
end
