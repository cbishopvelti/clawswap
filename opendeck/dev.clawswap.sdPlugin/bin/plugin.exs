# The clawswap plugin for OpenDeck (and the Elgato Stream Deck app). OpenDeck starts it (through
# bin/plugin) as
#   plugin -port <port> -pluginUUID <uuid> -registerEvent <event> -info <json>
# and it talks to OpenDeck over that WebSocket; see deck.ex for what the keys do.
Code.require_file("websocket.ex", __DIR__)
Code.require_file("deck.ex", __DIR__)

alias Clawswap.{Deck, WebSocket}

defmodule Clawswap.Plugin do
  def arg(args, name) do
    case Enum.drop_while(args, &(&1 != "-#{name}")) do
      [_, value | _] -> value
      _ -> nil
    end
  end

  # Reads OpenDeck's frames and hands each event to the keys; answers pings, and stops when OpenDeck goes.
  def loop(socket, deck, buffer) do
    {frames, rest} = WebSocket.decode(buffer)

    Enum.each(frames, fn
      {:text, text} ->
        case JSON.decode(text) do
          {:ok, message} -> Deck.handle(deck, message)
          _ -> IO.puts(:stderr, "clawswap plugin: not JSON: #{text}")
        end

      {:ping, payload} ->
        :gen_tcp.send(socket, WebSocket.frame(payload, :pong))

      {:close, _} ->
        System.halt(0)

      _ ->
        :ok
    end)

    case :gen_tcp.recv(socket, 0) do
      {:ok, data} -> loop(socket, deck, rest <> data)
      {:error, _} -> System.halt(0)
    end
  end
end

args = System.argv()
port = args |> Clawswap.Plugin.arg("port") |> String.to_integer()
uuid = Clawswap.Plugin.arg(args, "pluginUUID")
register = Clawswap.Plugin.arg(args, "registerEvent")

:inets.start()
{:ok, socket, rest} = WebSocket.connect("127.0.0.1", port)
send_json = fn message -> :gen_tcp.send(socket, WebSocket.frame(JSON.encode!(message))) end
send_json.(%{event: register, uuid: uuid})
{:ok, deck} = Deck.start_link(send: send_json, url: System.get_env("CLAWSWAP_URL"), log: &IO.puts/1)
Clawswap.Plugin.loop(socket, deck, rest)
