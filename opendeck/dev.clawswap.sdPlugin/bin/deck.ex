defmodule Clawswap.Deck do
  @moduledoc """
  The "clawswap branch" keys: each shows a branch from a clawswap watcher (the base branch, then the newest
  open PRs) and switches to it when pressed; "clawswap pull" pulls whatever branch the checkout is on.
  Each key names its watcher's URL, so one deck can drive several projects. See ../../../README.md.

  Options: `send` (posts one event to OpenDeck), `fetch` (`fn method, url, body -> {:ok, status, map} |
  {:error, reason}`, :httpc by default), `url` (the watcher for keys that don't name one), `schedule`
  (`fn ms -> ... end`, sends `:poll` after ms; tests pass a no-op), `log`.
  """

  use GenServer

  @branch_action "dev.clawswap.branch"
  @pull_action "dev.clawswap.pull"
  @default_url "http://127.0.0.1:8790"
  @poll_ms 1000
  @retry_ms 3000
  # A failed switch stays on its key this long.
  @failed_ms 60_000
  @colours %{current: "#3fb950", switching: "#e3b341", failed: "#e0503f", behind: "#58a6ff"}
  @muted "#a3abb8"

  def branch_action, do: @branch_action
  def pull_action, do: @pull_action

  @doc "Up to `lines` lines of about `width` characters, breaking at spaces, slashes and dashes."
  def wrap(text, width, lines) do
    words = Regex.scan(~r{[^\s/-]+[\s/-]*}u, text) |> Enum.map(&hd/1)

    out =
      Enum.reduce(words, [""], fn word, [line | done] ->
        if line != "" and String.length(String.trim_trailing(line <> word)) > width, do: [word, line | done], else: [line <> word | done]
      end)
      |> Enum.reverse()
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.map(&if(String.length(&1) > width, do: String.slice(&1, 0, width - 1) <> "…", else: &1))

    if length(out) > lines do
      {kept, _} = Enum.split(out, lines)
      List.update_at(kept, -1, &(String.slice(&1, 0, width - 1) <> "…"))
    else
      out
    end
  end

  defp escape_xml(text), do: String.replace(text, ~r/[<>&"]/, &%{"<" => "&lt;", ">" => "&gt;", "&" => "&amp;", ~s(") => "&quot;"}[&1])

  @doc """
  One key: a coloured bar for its state, the PR number, the merge status mark (top right) and tint, the
  title (or branch name), a status line, and a green outline on the checkout's branch.
  """
  def branch_image(look) do
    number = look[:number]
    mark = look[:mark]
    bar = look[:bar]
    status = look[:status]
    # The first row is the number and the mark's, when there are any.
    header = number || mark
    top = if header, do: 52, else: 34

    text =
      look.title
      |> wrap(11, if(header, do: 3, else: 4))
      |> Enum.with_index()
      |> Enum.map_join(fn {l, i} ->
        ~s(<text x="10" y="#{top + i * 21}" font-family="sans-serif" font-size="18" font-weight="600" fill="#eef1f5">#{escape_xml(l)}</text>)
      end)

    svg =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144"><rect width="144" height="144" fill="#{look[:background] || "#20242c"}"/>) <>
        if(bar, do: ~s(<rect width="144" height="10" fill="#{bar}"/>), else: "") <>
        if(number, do: ~s(<text x="10" y="30" font-family="sans-serif" font-size="16" fill="#{@muted}">##{number}</text>), else: "") <>
        if(mark,
          do: ~s(<text x="132" y="33" text-anchor="end" font-family="sans-serif" font-size="26" fill="#{look[:mark_colour] || @muted}">#{mark}</text>),
          else: ""
        ) <>
        text <>
        if(status && status != "",
          do: ~s(<text x="10" y="132" font-family="sans-serif" font-size="14" fill="#{bar || @muted}">#{escape_xml(String.slice(status, 0, 16))}</text>),
          else: ""
        ) <>
        if(look[:current], do: ~s(<rect x="3" y="3" width="138" height="138" rx="6" fill="none" stroke="#{@colours.current}" stroke-width="6"/>), else: "") <>
        "</svg>"

    "data:image/svg+xml," <> URI.encode(svg, &URI.char_unreserved?/1)
  end

  defp now, do: System.system_time(:millisecond)
  defp recently_failed?(run), do: run["phase"] == "failed" and now() - (run["at"] || 0) < @failed_ms

  @doc "What a key shows for `entry` (a branch from the watcher's state), or for no branch at all."
  def key_look(_state, nil), do: %{title: "No branch", status: ""}

  def key_look(state, entry) do
    look =
      Map.merge(
        %{title: get_in(entry, ["pr", "title"]) || entry["short"] || entry["branch"], number: get_in(entry, ["pr", "number"])},
        merge_mark(state, entry)
      )

    run = state["switch"] || %{}
    current = state["current"] || %{}
    targeted = run["target"] == entry["branch"]

    cond do
      targeted and run["phase"] == "running" ->
        Map.merge(look, %{bar: @colours.switching, status: run["step"] || "Switching"})

      targeted and recently_failed?(run) ->
        Map.merge(look, %{bar: @colours.failed, status: "Failed"})

      (current["branch"] == entry["branch"] and entry["sha"]) && current["sha"] != entry["sha"] ->
        Map.merge(look, %{bar: @colours.behind, status: "New commits", current: true})

      current["branch"] == entry["branch"] ->
        Map.merge(look, %{bar: @colours.current, status: if(state["dirty"], do: "Uncommitted", else: "Current"), current: true})

      true ->
        look
    end
  end

  @doc """
  The branch's merge status, with the page's marks in GitHub's colours, and a tint on the key so it shows
  from across the desk: ⎇ the base branch, ✓ merged into it (purple), ● open PR (green), ◌ draft PR
  (grey), ○ neither.
  """
  def merge_mark(state, entry) do
    cond do
      entry["branch"] == state["base"] -> %{mark: "⎇"}
      entry["merged"] -> %{mark: "✓", mark_colour: "#a371f7", background: "#2b2440"}
      get_in(entry, ["pr", "draft"]) -> %{mark: "◌", mark_colour: "#8b949e"}
      entry["pr"] -> %{mark: "●", mark_colour: "#3fb950", background: "#1d2e25"}
      true -> %{mark: "○"}
    end
  end

  @doc "What a pull key shows: the checkout's branch and whether GitHub has anything new for it."
  def pull_look(state) do
    branch = get_in(state, ["current", "branch"])
    short = branch && Enum.find_value(state["branches"] || [], branch, &(&1["branch"] == branch && &1["short"]))
    look = %{title: String.trim("Pull #{short}")}
    run = state["switch"] || %{}
    mine = run["pull"] == true and run["target"] == branch

    cond do
      mine and run["phase"] == "running" ->
        Map.merge(look, %{bar: @colours.switching, status: run["step"] || "Pulling"})

      mine and recently_failed?(run) ->
        Map.merge(look, %{bar: @colours.failed, status: "Failed"})

      state["upstream"] == nil ->
        Map.put(look, :status, "Not on GitHub")

      state["upstream"]["behind"] > 0 ->
        Map.merge(look, %{bar: @colours.behind, status: "#{state["upstream"]["behind"]} new commit#{if state["upstream"]["behind"] == 1, do: "", else: "s"}"})

      true ->
        Map.put(look, :status, "Up to date")
    end
  end

  @doc """
  Which branch each key shows: keys on "next branch" take the list in deck order (row by row), the first
  one the base branch; keys set to a branch name show that branch. `instances` are one watcher's keys.
  """
  def assign(instances, branches) do
    auto =
      instances
      |> Enum.filter(fn {_, i} -> not i.pull and blank?(i.settings["branch"]) end)
      |> Enum.sort_by(fn {_, i} -> {i.coordinates["row"] || 0, i.coordinates["column"] || 0} end)
      |> Enum.with_index()
      |> Map.new(fn {{context, _}, n} -> {context, Enum.at(branches, n)} end)

    Enum.reduce(instances, auto, fn {context, i}, acc ->
      name = i.settings["branch"]

      if not i.pull and not blank?(name),
        do: Map.put(acc, context, Enum.find(branches, &(&1["branch"] == name)) || %{"branch" => name, "missing" => true}),
        else: acc
    end)
  end

  defp blank?(value), do: value in [nil, ""]

  defp url_of(instance, fallback) do
    url = instance.settings["url"]
    url = if is_binary(url) and String.trim(url) != "", do: String.trim(url), else: fallback
    String.trim_trailing(url, "/")
  end

  # The GenServer: keys come and go as OpenDeck says, and their watchers are polled every second.

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Passes one OpenDeck event to the keys."
  def handle(deck, message), do: GenServer.call(deck, {:message, message})

  @doc "Polls the watchers now and redraws."
  def poll(deck), do: GenServer.call(deck, :poll)

  @impl true
  def init(opts) do
    me = self()

    {:ok,
     %{
       send: Keyword.fetch!(opts, :send),
       fetch: opts[:fetch] || (&fetch/3),
       url: opts[:url] || @default_url,
       schedule: opts[:schedule] || fn ms -> Process.send_after(me, :poll, ms) end,
       log: opts[:log] || fn _ -> :ok end,
       # context -> %{settings, coordinates, pull, image}
       instances: %{},
       # url -> %{state} | %{error}
       watchers: %{},
       # context -> branch entry
       shown: %{},
       timer: nil
     }}
  end

  @impl true
  def handle_call(:poll, _from, s), do: {:reply, :ok, do_poll(s)}
  def handle_call({:message, message}, _from, s), do: {:reply, :ok, on_message(message, s)}

  @impl true
  def handle_info(:poll, s), do: {:noreply, do_poll(%{s | timer: nil})}

  defp on_message(%{"event" => "willAppear", "context" => context} = m, s) do
    payload = m["payload"] || %{}
    instance = %{settings: payload["settings"] || %{}, coordinates: payload["coordinates"] || %{}, pull: m["action"] == @pull_action, image: nil}
    s.send.(%{event: "setTitle", context: context, payload: %{title: "", target: 0}})
    s |> put_in([:instances, context], instance) |> draw() |> schedule(0)
  end

  defp on_message(%{"event" => "willDisappear", "context" => context}, s) do
    s = %{s | instances: Map.delete(s.instances, context)}
    if s.instances == %{}, do: s, else: draw(s)
  end

  defp on_message(%{"event" => "didReceiveSettings", "context" => context} = m, s) do
    payload = m["payload"] || %{}

    s =
      case s.instances[context] do
        nil -> s
        i -> put_in(s.instances[context], %{i | settings: payload["settings"] || %{}, coordinates: payload["coordinates"] || i.coordinates, image: nil})
      end

    s |> draw() |> schedule(0)
  end

  defp on_message(%{"event" => "keyDown", "context" => context}, s), do: press(context, s)
  defp on_message(_, s), do: s

  defp groups(s), do: Enum.group_by(s.instances, fn {_, i} -> url_of(i, s.url) end)

  defp set_image(s, context, image) do
    if s.instances[context].image == image do
      s
    else
      s.send.(%{event: "setImage", context: context, payload: %{image: image, target: 0}})
      put_in(s.instances[context].image, image)
    end
  end

  defp draw(s) do
    Enum.reduce(groups(s), %{s | shown: %{}}, fn {url, group}, s ->
      case s.watchers[url] do
        %{state: state} ->
          shown = assign(group, state["branches"] || [])
          s = %{s | shown: Map.merge(s.shown, shown)}

          Enum.reduce(group, s, fn {context, i}, s ->
            entry = shown[context]

            look =
              cond do
                i.pull -> pull_look(state)
                entry && entry["missing"] -> %{title: entry["branch"], status: "Not listed"}
                true -> key_look(state, entry)
              end

            set_image(s, context, branch_image(look))
          end)

        other ->
          error = other && other[:error]
          look = %{title: "clawswap", status: error || "Connecting", bar: error && @colours.failed}
          Enum.reduce(group, s, fn {context, _}, s -> set_image(s, context, branch_image(look)) end)
      end
    end)
  end

  defp schedule(s, ms) do
    if s.timer, do: Process.cancel_timer(s.timer)
    %{s | timer: if(s.instances != %{}, do: s.schedule.(ms))}
  end

  defp do_poll(s) do
    {watchers, failed} =
      Enum.reduce(Map.keys(groups(s)), {s.watchers, false}, fn url, {watchers, failed} ->
        case s.fetch.(:get, "#{url}/state", nil) do
          {:ok, 200, state} ->
            {Map.put(watchers, url, %{state: state}), failed}

          _ ->
            if watchers[url][:error] != "Not running", do: s.log.("clawswap at #{url}: not running")
            {Map.put(watchers, url, %{error: "Not running"}), true}
        end
      end)

    %{s | watchers: watchers} |> draw() |> schedule(if failed, do: @retry_ms, else: @poll_ms)
  end

  defp press(context, s) do
    instance = s.instances[context]
    entry = s.shown[context]

    if instance == nil or (not instance.pull and (entry == nil or entry["missing"])) do
      s.send.(%{event: "showAlert", context: context})
      s
    else
      url = url_of(instance, s.url)
      answer = if instance.pull, do: s.fetch.(:post, "#{url}/pull", %{}), else: s.fetch.(:post, "#{url}/switch", %{branch: entry["branch"]})

      case answer do
        {:ok, status, body} when status in 200..299 ->
          # Nothing new: a tick, since the key doesn't change.
          if instance.pull and get_in(body, ["switch", "phase"]) == "done", do: s.send.(%{event: "showOk", context: context})

        {:ok, _, body} ->
          s.log.("clawswap: #{body["error"]}")
          s.send.(%{event: "showAlert", context: context})

        {:error, _} ->
          s.send.(%{event: "showAlert", context: context})
      end

      schedule(s, 0)
    end
  end

  @doc "The watcher's API over :httpc."
  def fetch(method, url, body) do
    request =
      case method do
        :get -> {String.to_charlist(url), []}
        :post -> {String.to_charlist(url), [], ~c"application/json", JSON.encode!(body)}
      end

    case :httpc.request(method, request, [timeout: 120_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, text}} ->
        case JSON.decode(text) do
          {:ok, map} -> {:ok, status, map}
          _ -> {:error, :bad_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
