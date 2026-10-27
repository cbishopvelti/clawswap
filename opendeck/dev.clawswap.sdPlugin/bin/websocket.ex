defmodule Clawswap.WebSocket do
  @moduledoc """
  Just enough of a WebSocket client (RFC 6455) to talk to OpenDeck on localhost: the handshake, masked
  text frames out, and unmasked frames in. OpenDeck's messages are small JSON texts.
  """

  @doc "Connects and upgrades: `{:ok, socket, rest}`, where rest is whatever came after the handshake."
  def connect(host, port, path \\ "/") do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    with {:ok, socket} <- :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5000),
         :ok <-
           :gen_tcp.send(socket, [
             "GET #{path} HTTP/1.1\r\nHost: #{host}:#{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
             "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
           ]),
         {:ok, head, rest} <- read_head(socket, ""),
         true <- head =~ ~r{^HTTP/1\.1 101} || {:error, {:handshake, head}} do
      {:ok, socket, rest}
    end
  end

  defp read_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_] ->
        case :gen_tcp.recv(socket, 0, 5000) do
          {:ok, data} -> read_head(socket, acc <> data)
          error -> error
        end
    end
  end

  @doc "A masked frame, as a client must send: :text by default, or :pong / :close."
  def frame(payload, opcode \\ :text) do
    code = %{text: 0x1, close: 0x8, ping: 0x9, pong: 0xA}[opcode]
    mask = :crypto.strong_rand_bytes(4)
    size = byte_size(payload)

    length =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    <<1::1, 0::3, code::4>> <> length <> mask <> apply_mask(payload, mask)
  end

  defp apply_mask(payload, <<m::binary-size(4)>>) do
    mask = :binary.copy(m, div(byte_size(payload), 4) + 1) |> binary_part(0, byte_size(payload))
    :crypto.exor(payload, mask)
  end

  @doc """
  Splits received bytes into frames: `{[{opcode, payload}], rest}` with opcode :text, :binary, :close,
  :ping or :pong, keeping an unfinished frame in rest. Fragmented messages are joined.
  """
  def decode(buffer, frames \\ [], partial \\ nil)

  def decode(<<fin::1, _::3, code::4, masked::1, len::7, rest::binary>> = buffer, frames, partial) do
    {len, rest} =
      case len do
        126 when byte_size(rest) >= 2 ->
          <<n::16, r::binary>> = rest
          {n, r}

        127 when byte_size(rest) >= 8 ->
          <<n::64, r::binary>> = rest
          {n, r}

        n when n < 126 ->
          {n, rest}

        _ ->
          {nil, rest}
      end

    mask_size = if masked == 1, do: 4, else: 0

    if len != nil and byte_size(rest) >= mask_size + len do
      <<mask::binary-size(mask_size), payload::binary-size(len), rest::binary>> = rest
      payload = if masked == 1, do: apply_mask(payload, mask), else: payload
      {frames, partial} = add(frames, partial, opcode(code), payload, fin == 1)
      decode(rest, frames, partial)
    else
      {Enum.reverse(frames), buffer}
    end
  end

  def decode(buffer, frames, _partial), do: {Enum.reverse(frames), buffer}

  defp add(frames, nil, :continuation, _payload, _fin), do: {frames, nil}
  defp add(frames, {code, acc}, :continuation, payload, true), do: {[{code, acc <> payload} | frames], nil}
  defp add(frames, {code, acc}, :continuation, payload, false), do: {frames, {code, acc <> payload}}
  defp add(frames, partial, code, payload, true), do: {[{code, payload} | frames], partial}
  defp add(frames, _partial, code, payload, false), do: {frames, {code, payload}}

  defp opcode(0x0), do: :continuation
  defp opcode(0x1), do: :text
  defp opcode(0x2), do: :binary
  defp opcode(0x8), do: :close
  defp opcode(0x9), do: :ping
  defp opcode(0xA), do: :pong
  defp opcode(_), do: :unknown
end
