defmodule Clawswap.SharedSmee do
  @moduledoc """
  The daemon's one smee.io channel, which every project's GitHub webhook sends to, so no project needs a
  channel of its own. It's made the first time the daemon starts and kept in
  `$XDG_STATE_HOME/clawswap/smee.json` (`file/0`), so the webhooks stay right across restarts. The file
  also keeps when each repo's last delivery came in, so a webhook that's been seen working (one added by
  hand, with no token to look for it with) still shows as working after a restart.

  Each watcher without a channel of its own `subscribe/2`s with its repo (owner/name). The first time a
  repo comes in, this makes sure it has the webhook for the channel (with the token the PR list uses);
  each delivery then goes only to the watchers of the repo it names (to all of them when it names none).
  As with a channel of its own, a delivery is only a hint to look again.

  A subscriber gets `{:shared_smee, {:status, %{webhook, error}}}` whenever its webhook's state changes
  (`webhook`: "connecting", "connected", "unchecked" or "off", as the watcher's view has it; "unchecked"
  when there's no token to look for the webhook with, though it listens all the same, and a webhook added
  by hand that sends to the channel works: its first delivery makes it "connected", and from then on, across
  restarts, it starts "connected"), `{:shared_smee,
  {:delivery, github_event}}` for each delivery about its repo, and `{:shared_smee, {:log, text}}` for what
  its project's log should say (the webhook was added, or couldn't be).

  Options: `file`, `new_channel` (makes a channel: `Clawswap.Smee.new_channel/0`), `ensure_hook` (called
  with the repo and the channel: `{:ok, :created | :exists}` or `{:error, message}`), `listen` (starts a
  listener on the channel for the calling process: `Clawswap.Smee.start_link/1`'s), `name`.
  """

  use GenServer

  alias Clawswap.{GitHub, Smee}

  @doc "Where the channel is kept: `$XDG_STATE_HOME/clawswap/smee.json` (`~/.local/state` without it)."
  def file do
    state = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
    Path.join([state, "clawswap", "smee.json"])
  end

  @doc "The shared channel kept in `file`, or nil before there is one."
  def channel(file \\ file()) do
    with {:ok, text} <- File.read(file), {:ok, %{"channel" => "http" <> _ = url}} <- JSON.decode(text) do
      url
    else
      _ -> nil
    end
  end

  @doc "The shared channel, made (and kept in `file`) when there isn't one yet: `{:ok, url}` or `{:error, message}`."
  def ensure_channel(file \\ file(), new_channel \\ &Smee.new_channel/0) do
    case channel(file) do
      nil ->
        with {:ok, url} <- new_channel.() do
          File.mkdir_p!(Path.dirname(file))
          File.write!(file, JSON.encode!(%{channel: url}) <> "\n")
          {:ok, url}
        end

      url ->
        {:ok, url}
    end
  end

  @doc "When the last delivery about `repo` came in on the channel kept in `file`, or nil if none ever has."
  def last_delivery(file \\ file(), repo) do
    with {:ok, text} <- File.read(file),
         {:ok, %{"deliveries" => %{} = deliveries}} <- JSON.decode(text),
         at when is_binary(at) <- deliveries[key(repo)],
         {:ok, at, _} <- DateTime.from_iso8601(at) do
      at
    else
      _ -> nil
    end
  end

  @doc "Keeps in `file` that a delivery about `repo` came in `at`."
  def remember_delivery(file \\ file(), repo, at) do
    with {:ok, text} <- File.read(file), {:ok, %{} = kept} <- JSON.decode(text) do
      deliveries = Map.put(kept["deliveries"] || %{}, key(repo), DateTime.to_iso8601(DateTime.truncate(at, :second)))
      File.write!(file, JSON.encode!(Map.put(kept, "deliveries", deliveries)) <> "\n")
    end

    :ok
  end

  @doc """
  Adds `repo`'s webhook for `channel` with the GitHub token, when it may: `{:ok, :created | :exists}`,
  `{:error, :no_token}` (it can't even look, so a webhook added by hand may well be there) or
  `{:error, message}`.
  """
  def ensure_hook(repo, channel) do
    case GitHub.token() do
      nil ->
        {:error, :no_token}

      token ->
        with {:ok, outcome, _removed} <- GitHub.ensure_hook(repo, token, channel, nil, fn _ -> false end), do: {:ok, outcome}
    end
  end

  @doc "Whether the daemon's shared channel is running (it isn't outside the daemon, or in most tests)."
  def running?(server \\ __MODULE__), do: is_pid(GenServer.whereis(server))

  @doc """
  Sends the calling process the deliveries about `repo` (owner/name, or nil when origin isn't on GitHub)
  from now on, until it exits or `unsubscribe/1`s, and returns its webhook's state as it is now (as
  `{:status, ...}` would say it).
  """
  def subscribe(server \\ __MODULE__, repo), do: GenServer.call(server, {:subscribe, self(), repo})

  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, {:unsubscribe, self()})

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      file: opts[:file] || file(),
      new_channel: opts[:new_channel] || (&Smee.new_channel/0),
      ensure_hook: opts[:ensure_hook] || (&ensure_hook/2),
      listen: opts[:listen] || (&Smee.start_link/1),
      channel: nil,
      # The channel couldn't be made: why (it's tried again, waiting longer each time up to 10 minutes).
      channel_error: nil,
      retry_ms: 5_000,
      listener: nil,
      # "connecting" or "connected", and why it was lost.
      stream: "connecting",
      stream_error: nil,
      # By repo (lower case, as GitHub's names aren't case-sensitive): :pending, :ok or {:error, message}.
      hooks: %{},
      # pid => {repo, monitor}
      subs: %{},
      # By repo: when its last delivery was written to the file (it's written at most once a minute).
      remembered: %{}
    }

    {:ok, state, {:continue, :channel}}
  end

  @impl true
  def handle_continue(:channel, state) do
    case channel(state.file) do
      nil -> {:noreply, make_channel(state)}
      url -> {:noreply, follow(state, url)}
    end
  end

  @impl true
  def handle_call({:subscribe, pid, repo}, _from, state) do
    state = drop_sub(state, pid)
    state = %{state | subs: Map.put(state.subs, pid, {repo, Process.monitor(pid)})}
    state = check_hook(state, repo)
    {:reply, status(state, repo), state}
  end

  def handle_call({:unsubscribe, pid}, _from, state), do: {:reply, :ok, drop_sub(state, pid)}

  @impl true
  def handle_info({:channel, {:ok, url}}, state) do
    log("Made the shared smee.io channel #{url} (kept in #{state.file})")
    state = follow(%{state | channel_error: nil}, url)
    # The repos that came in before it was made.
    repos = state.subs |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    {:noreply, Enum.reduce(repos, state, &check_hook(&2, &1))}
  end

  def handle_info({:channel, {:error, message}}, state) do
    log("Couldn't make the shared smee.io channel (#{message}); trying again in #{div(state.retry_ms, 1000)} s")
    Process.send_after(self(), :make_channel, state.retry_ms)
    state = %{state | channel_error: message, retry_ms: min(state.retry_ms * 2, 600_000)}
    {:noreply, tell_all(state)}
  end

  def handle_info(:make_channel, state), do: {:noreply, make_channel(state)}

  def handle_info({:hook, repo, result}, state) do
    key = key(repo)

    {hook, note} =
      case result do
        {:ok, :created} ->
          {:ok, "Added #{repo}'s GitHub webhook for the shared smee.io channel"}

        {:ok, :exists} ->
          {:ok, nil}

        # No token to ask GitHub with, so go by whether a delivery has ever come in.
        {:error, :no_token} ->
          case last_delivery(state.file, repo) do
            nil ->
              {:unchecked,
               "Listening for #{repo}'s GitHub webhook on #{state.channel}; nothing has come from it yet. With no " <>
                 "GitHub token clawswap can't ask GitHub whether it's there, so it says connected when the first " <>
                 "delivery comes in (the next push, or Redeliver the ping on the webhook's page on GitHub). To have " <>
                 "clawswap add the webhook itself: gh auth login, then clawswap smee"}

            at ->
              {:ok, "#{repo}'s GitHub webhook is connected (last delivery #{ago(at)}, on #{state.channel})"}
          end

        {:error, message} ->
          {{:error, message},
           "Couldn't add #{repo}'s GitHub webhook (#{message}); listening on #{state.channel} all the same, so add one " <>
             "by hand that sends there, or run clawswap smee to try again. Looking for new branches every 15 minutes meanwhile"}
      end

    if note, do: log(note)
    state = put_in(state.hooks[key], hook)
    for pid <- subscribers(state, repo), note, do: send(pid, {:shared_smee, {:log, note}})
    {:noreply, tell(state, repo)}
  end

  def handle_info({:smee, :open}, state), do: {:noreply, tell_all(%{state | stream: "connected", stream_error: nil})}

  def handle_info({:smee, {:drop, reason}}, state), do: {:noreply, tell_all(%{state | stream: "connecting", stream_error: reason})}

  def handle_info({:smee, {:delivery, kind, repo}}, state) do
    pids = if repo, do: subscribers(state, repo), else: Map.keys(state.subs)
    Enum.each(pids, &send(&1, {:shared_smee, {:delivery, kind}}))
    {:noreply, delivered(state, repo)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state), do: {:noreply, drop_sub(state, pid)}

  def handle_info(_, state), do: {:noreply, state}

  # A delivery about a repo means its webhook works, whether or not it could be checked or added (one added
  # by hand, with no token to look for it with).
  defp delivered(state, nil), do: state

  defp delivered(state, repo) do
    state = remember(state, repo)

    case state.hooks[key(repo)] do
      # Not yet known (or still being checked, which says for itself).
      hook when hook in [nil, :ok, :pending] ->
        state

      _ ->
        note = "Got a delivery from #{repo}'s GitHub webhook, so it's connected"
        log(note)
        for pid <- subscribers(state, repo), do: send(pid, {:shared_smee, {:log, note}})
        tell(put_in(state.hooks[key(repo)], :ok), repo)
    end
  end

  # Kept in the file at most once a minute, so a busy repo doesn't write it on every push.
  defp remember(state, repo) do
    now = DateTime.utc_now()

    case state.remembered[key(repo)] do
      %DateTime{} = at ->
        if DateTime.diff(now, at) < 60, do: state, else: keep(state, repo, now)

      _ ->
        keep(state, repo, now)
    end
  end

  defp keep(state, repo, now) do
    remember_delivery(state.file, repo, now)
    put_in(state.remembered[key(repo)], now)
  end

  @doc "How long ago `at` was, said roughly (\"just now\", \"5 min ago\", \"3 h ago\", \"2 days ago\")."
  def ago(at, now \\ DateTime.utc_now()) do
    s = max(DateTime.diff(now, at), 0)

    cond do
      s < 60 -> "just now"
      s < 3600 -> "#{div(s, 60)} min ago"
      s < 86_400 -> "#{div(s, 3600)} h ago"
      true -> "#{div(s, 86_400)} days ago"
    end
  end

  defp make_channel(state) do
    me = self()
    %{file: file, new_channel: new_channel} = state
    Task.start(fn -> send(me, {:channel, ensure_channel(file, new_channel)}) end)
    state
  end

  defp follow(state, url) do
    {:ok, pid} = state.listen.(url: url, owner: self(), log: &log/1)
    %{state | channel: url, listener: pid}
  end

  # The first time a repo comes in (and again after it failed), make sure it has the webhook.
  defp check_hook(%{channel: nil} = state, _repo), do: state
  defp check_hook(state, nil), do: state

  defp check_hook(state, repo) do
    case state.hooks[key(repo)] do
      hook when hook in [:ok, :pending] ->
        state

      _ ->
        me = self()
        %{ensure_hook: ensure_hook, channel: channel} = state
        Task.start(fn -> send(me, {:hook, repo, ensure_hook.(repo, channel)}) end)
        put_in(state.hooks[key(repo)], :pending)
    end
  end

  defp status(_state, nil), do: %{webhook: "off", error: "origin isn't a GitHub repo"}
  defp status(%{channel: nil, channel_error: error}, _repo), do: %{webhook: "connecting", error: error}

  defp status(state, repo) do
    case state.hooks[key(repo)] do
      {:error, message} -> %{webhook: "off", error: message}
      :ok -> %{webhook: state.stream, error: state.stream_error}
      :unchecked when state.stream == "connected" -> %{webhook: "unchecked", error: "no delivery yet on #{state.channel} (no GitHub token to check it with)"}
      :unchecked -> %{webhook: "connecting", error: state.stream_error}
      _ -> %{webhook: "connecting", error: nil}
    end
  end

  defp tell(state, repo) do
    for pid <- subscribers(state, repo), do: send(pid, {:shared_smee, {:status, status(state, repo)}})
    state
  end

  defp tell_all(state) do
    for {pid, {repo, _}} <- state.subs, do: send(pid, {:shared_smee, {:status, status(state, repo)}})
    state
  end

  defp subscribers(state, repo), do: for({pid, {r, _}} <- state.subs, r != nil and key(r) == key(repo), do: pid)

  defp drop_sub(state, pid) do
    case Map.pop(state.subs, pid) do
      {nil, _} ->
        state

      {{_, ref}, subs} ->
        Process.demonitor(ref, [:flush])
        %{state | subs: subs}
    end
  end

  defp key(repo), do: String.downcase(repo)

  defp log(text), do: Clawswap.Watcher.log(text)
end
