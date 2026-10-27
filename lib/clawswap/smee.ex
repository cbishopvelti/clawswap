defmodule Clawswap.Smee do
  @moduledoc """
  Listens to a smee.io channel, which relays the GitHub webhook to this machine (it has no public URL).
  smee.io serves the channel as Server-Sent Events: a "ready" event, "ping"s, and one plain message per
  delivery whose data is the request's headers with `body` and `query` added.

  The watcher only takes a delivery as a hint to look again: anyone who knows the channel URL can post to
  it, so nothing in the payload is acted on.

  The listener sends its owner `{:smee, :open}` each time the stream (re)connects, `{:smee, {:drop,
  reason}}` when it's lost and `{:smee, {:delivery, github_event}}` for each delivery. It reconnects after
  an error, waiting longer each time up to a minute.
  """

  use GenServer

  @doc "Splits a chunk of an event stream into events, keeping an unfinished one for the next chunk."
  def parse_events(buffer) do
    blocks = buffer |> String.replace(~r/\r\n?/, "\n") |> String.split("\n\n")
    {blocks, [rest]} = Enum.split(blocks, -1)

    events =
      for block <- blocks do
        Enum.reduce(String.split(block, "\n"), %{event: "message", data: []}, fn line, acc ->
          cond do
            line == "" or String.starts_with?(line, ":") ->
              acc

            true ->
              {field, value} =
                case String.split(line, ":", parts: 2) do
                  [field] -> {field, ""}
                  [field, value] -> {field, String.replace_prefix(value, " ", "")}
                end

              case field do
                "event" -> %{acc | event: value}
                "data" -> %{acc | data: acc.data ++ [value]}
                _ -> acc
              end
          end
        end)
        |> then(&%{&1 | data: Enum.join(&1.data, "\n")})
      end

    {events, rest}
  end

  @doc "The GitHub event a delivery carries (\"push\", \"create\", \"pull_request\"...), or nil for anything else."
  def github_event(data) do
    case JSON.decode(data) do
      {:ok, %{"x-github-event" => kind}} when is_binary(kind) -> kind
      _ -> nil
    end
  end

  @doc "A new channel URL: smee.io/new redirects to one."
  def new_channel do
    :inets.start()
    :ssl.start()

    case :httpc.request(:head, {~c"https://smee.io/new", []}, [ssl: Clawswap.GitHub.ssl_options(), autoredirect: false], []) do
      {:ok, {{_, status, _}, headers, _}} ->
        case List.keyfind(headers, ~c"location", 0) do
          {_, location} -> {:ok, URI.merge("https://smee.io", to_string(location)) |> to_string()}
          nil -> {:error, "smee.io didn't make a channel (#{status})"}
        end

      {:error, reason} ->
        {:error, "smee.io: #{inspect(reason)}"}
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      url: URI.parse(Keyword.fetch!(opts, :url)),
      owner: Keyword.fetch!(opts, :owner),
      log: opts[:log] || fn _ -> :ok end,
      socket: nil,
      transport: nil,
      phase: :headers,
      raw: "",
      chunked: false,
      buffer: "",
      delay: 1000
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_info(:connect, state), do: {:noreply, connect(state)}

  def handle_info({kind, socket, data}, %{socket: socket} = state) when kind in [:tcp, :ssl] do
    set_active(state)

    case received(%{state | raw: state.raw <> data}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, retry(state, reason)}
    end
  end

  def handle_info({kind, socket}, %{socket: socket} = state) when kind in [:tcp_closed, :ssl_closed], do: {:noreply, retry(state, "smee closed the stream")}

  def handle_info({kind, socket, reason}, %{socket: socket} = state) when kind in [:tcp_error, :ssl_error], do: {:noreply, retry(state, inspect(reason))}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: close(state)

  # A plain HTTP/1.1 GET over :gen_tcp or :ssl, so the stream can be read as it comes.
  defp connect(state) do
    %URI{scheme: scheme, host: host, port: port} = url = state.url
    host_cl = String.to_charlist(host)

    result =
      if scheme == "https" do
        :ssl.start()
        :ssl.connect(host_cl, port, [:binary, active: :once, server_name_indication: host_cl] ++ Clawswap.GitHub.ssl_options(), 15_000)
      else
        :gen_tcp.connect(host_cl, port, [:binary, active: :once], 15_000)
      end

    case result do
      {:ok, socket} ->
        transport = if scheme == "https", do: :ssl, else: :gen_tcp
        path = (url.path || "/") <> if(url.query, do: "?" <> url.query, else: "")
        request = "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nAccept: text/event-stream\r\nUser-Agent: clawswap\r\nCache-Control: no-cache\r\n\r\n"
        transport.send(socket, request)
        %{state | socket: socket, transport: transport, phase: :headers, raw: "", chunked: false, buffer: ""}

      {:error, reason} ->
        retry(state, inspect(reason))
    end
  end

  defp set_active(%{transport: :ssl, socket: socket}), do: :ssl.setopts(socket, active: :once)
  defp set_active(%{socket: socket}), do: :inet.setopts(socket, active: :once)

  defp close(%{socket: nil}), do: :ok
  defp close(%{transport: transport, socket: socket}), do: transport.close(socket)

  defp received(%{phase: :headers, raw: raw} = state) do
    case :binary.split(raw, "\r\n\r\n") do
      [head, rest] ->
        [status_line | headers] = String.split(head, "\r\n")

        case Regex.run(~r{^HTTP/1\.[01] (\d+)}, status_line) do
          [_, "200"] ->
            chunked = Enum.any?(headers, &(String.downcase(&1) =~ ~r/^transfer-encoding:\s*chunked/))
            received(%{state | phase: :body, raw: rest, chunked: chunked})

          [_, status] ->
            {:error, "smee answered #{status}", state}

          nil ->
            {:error, "smee sent something that isn't HTTP", state}
        end

      [_] ->
        {:ok, state}
    end
  end

  defp received(%{phase: :body, chunked: false} = state), do: {:ok, events(%{state | raw: ""}, state.raw)}

  defp received(%{phase: :body} = state) do
    case dechunk(state.raw, "") do
      {:ok, text, rest} -> {:ok, events(%{state | raw: rest}, text)}
      {:end, text} -> {:error, "smee closed the stream", events(state, text)}
    end
  end

  # Takes the complete chunks off the front of `raw`.
  defp dechunk(raw, acc) do
    with [size_line, rest] <- :binary.split(raw, "\r\n"),
         {size, _} <- Integer.parse(size_line, 16) do
      cond do
        size == 0 -> {:end, acc}
        byte_size(rest) >= size + 2 -> dechunk(binary_part(rest, size + 2, byte_size(rest) - size - 2), acc <> binary_part(rest, 0, size))
        true -> {:ok, acc, raw}
      end
    else
      _ -> {:ok, acc, raw}
    end
  end

  defp events(state, text) do
    {events, rest} = parse_events(state.buffer <> text)

    Enum.reduce(events, %{state | buffer: rest}, fn
      %{event: "ready"}, state ->
        state.log.("Listening for GitHub webhooks on smee.io")
        send(state.owner, {:smee, :open})
        %{state | delay: 1000}

      %{event: "message", data: data}, state ->
        if kind = github_event(data), do: send(state.owner, {:smee, {:delivery, kind}})
        state

      _, state ->
        state
    end)
  end

  defp retry(state, reason) do
    close(state)
    send(state.owner, {:smee, {:drop, reason}})
    state.log.("smee: #{reason}; reconnecting in #{div(state.delay, 1000)} s")
    Process.send_after(self(), :connect, state.delay)
    %{state | socket: nil, delay: min(state.delay * 2, 60_000)}
  end
end
