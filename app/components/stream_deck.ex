defmodule ClawswapWeb.StreamDeck do
  @moduledoc """
  Drives a Stream Deck from the page itself, over WebHID, instead of through OpenDeck: "Connect Stream
  Deck" asks the browser for the deck, and from then on its keys show the page's branches (the base
  branch first, then the newest PRs) with Pull on the last key. Tapping one switches; holding one for half a
  second opens the Claude Code thread that made its branch (the checkout's, on Pull). Chrome remembers
  the deck, so the page opens it again by itself next time, and when it's plugged back in.

  It's all browser APIs (navigator.hid, OffscreenCanvas) called through Hologram's JS interop, so this
  runs on the client. The key images are the OpenDeck plugin's SVGs (`ClawswapWeb.View.keys/1`), turned
  into the JPEG the deck wants on a canvas.

  The models it knows are the ones that take 72 or 96 pixel JPEG keys: the Stream Deck (v2), MK.2 and XL.
  Their key reports and image reports are as python-elgato-streamdeck documents them.
  """

  use Hologram.Component
  use Hologram.JS

  alias Clawswap.Watcher

  prop(:keys, :map)

  @vendor 0x0FD9
  # Product id => {name, number of keys, key size in pixels}.
  @models %{
    0x006D => {"Stream Deck", 15, 72},
    0x0080 => {"Stream Deck MK.2", 15, 72},
    0x00A5 => {"Stream Deck MK.2", 15, 72},
    0x006C => {"Stream Deck XL", 32, 96},
    0x008F => {"Stream Deck XL", 32, 96}
  }
  # An image goes to the deck in output reports 2 of this many bytes (after the report id), each a
  # 7 byte header and then a page of the JPEG.
  @report_bytes 1023
  # Holding a key this long opens its branch's Claude Code thread instead of switching.
  @hold_ms 500
  @header_bytes 7

  def init(props, component, _server) do
    component
    |> put_state(keys: props.keys, model: nil, count: 0, size: 0, sent: %{}, pressed: [], holds: %{}, presses: 0, message: nil)
    |> put_action(:reconnect)
  end

  def template do
    ~HOLO"""
    <span class="deck">
      {%if @model}
        <span class="deck-on" title="Its keys show these branches; the last one pulls">{@model}</span>
      {%else}
        <button class="pull" $click="connect">Connect Stream Deck</button>
      {/if}
      {%if @message}<span class="deck-message">{@message}</span>{/if}
    </span>
    """
  end

  # On load, and when a deck is plugged in: open one Chrome already let this page use.
  def action(:reconnect, _params, component) do
    if supported?() and component.state.model == nil do
      listen_for_plugging()

      case hid() |> JS.call(:getDevices, []) |> Task.await() |> Enum.find(&known?/1) do
        nil -> component
        device -> open(component, device)
      end
    else
      component
    end
  end

  # The button: Chrome lists the decks it can see and the user picks one.
  def action(:connect, _params, component) do
    cond do
      not supported?() ->
        put_state(component, :message, "This needs WebHID: Chrome or Edge, on http://127.0.0.1 or https.")

      not allowed?() ->
        put_state(component, :message, "Open the watcher's page on its own: an iframe needs allow=\"hid\" for this.")

      true ->
        listen_for_plugging()
        filters = Enum.map(Map.keys(@models), &%{vendorId: @vendor, productId: &1})

        # Cancelling the browser's chooser gives no devices.
        case hid() |> JS.call(:requestDevice, [%{filters: filters}]) |> Task.await() do
          [device | _] -> open(component, device)
          [] -> component
        end
    end
  end

  # The page's branches changed.
  def action(:draw, params, component) do
    component = put_state(component, :keys, params.keys)
    if component.state.model, do: draw(component), else: component
  end

  # An input report: which keys are down now, 1 or 0 each. A key does its thing when it's let go, unless
  # it was held long enough to open its branch's Claude Code thread instead (:held, below).
  def action(:keys, params, component) do
    before = component.state.pressed
    changed = fn now -> params.keys |> Enum.with_index() |> Enum.find_value(fn {down, key} -> down == now and Enum.at(before, key, 0) != now and key end) end
    component = put_state(component, :pressed, params.keys)

    # A report says one change at a time (and a component chains one action or command), so one each.
    case {changed.(1), changed.(0)} do
      {nil, nil} ->
        component

      {down, nil} ->
        press = component.state.presses + 1

        component
        |> put_state(presses: press, holds: Map.put(component.state.holds, down, {press, params.at}))
        |> put_action(name: :held, params: %{key: down, press: press}, delay: @hold_ms)

      {_, up} ->
        {hold, holds} = Map.pop(component.state.holds, up)
        component = put_state(component, :holds, holds)

        case hold do
          # :held may run late, behind a redraw that's still sending images, so the reports' times decide
          # too (taken as they came in, as this action may be late as well).
          {_press, at} -> if params.at - at >= @hold_ms, do: open_claude(component, up), else: press(component, up)
          _ -> component
        end
    end
  end

  # A key still down since this press: open its branch's Claude Code thread.
  def action(:held, params, component) do
    case component.state.holds[params.key] do
      {press, _at} when press == params.press ->
        component
        |> put_state(:holds, Map.put(component.state.holds, params.key, :held))
        |> open_claude(params.key)

      _ ->
        component
    end
  end

  # A deck was unplugged; if it was ours, forget it.
  def action(:gone, _params, component) do
    if component.state.model != nil and not opened?(deck()),
      do: put_state(component, model: nil, sent: %{}, pressed: []),
      else: component
  end

  def command(:switch, params, server), do: answer(server, Watcher.switch_to(params.branch))
  def command(:pull, _params, server), do: answer(server, Watcher.pull())
  def command(:claude, params, server), do: answer(server, Watcher.open_claude(params.branch))

  defp answer(server, {:ok, _state}), do: put_action(server, name: :show_message, target: "page", params: %{message: nil})
  defp answer(server, {:error, _status, message}), do: put_action(server, name: :show_message, target: "page", params: %{message: message})

  @doc "What each of a deck's `count` keys shows, in key order: the branches that fit, blanks, then Pull."
  def key_images(keys, count) do
    branches = keys.branches |> Enum.take(count - 1) |> Enum.map(& &1.image)
    branches ++ List.duplicate(nil, count - 1 - length(branches)) ++ [keys.pull]
  end

  @doc "What pressing `key` does: `{:switch, branch}`, `:pull`, or nothing for a blank key."
  def key_command(keys, count, key) do
    cond do
      key == count - 1 -> :pull
      entry = Enum.at(keys.branches, key) -> {:switch, entry.branch}
      true -> nil
    end
  end

  defp open_claude(component, key) do
    case key_command(component.state.keys, component.state.count, key) do
      :pull -> put_command(component, :claude, branch: nil)
      {:switch, branch} -> put_command(component, :claude, branch: branch)
      nil -> component
    end
  end

  defp press(component, key) do
    case key_command(component.state.keys, component.state.count, key) do
      :pull -> put_command(component, :pull)
      {:switch, branch} -> put_command(component, :switch, branch: branch)
      nil -> component
    end
  end

  # A rejected promise can't be rescued on the client, so these are checked first instead.
  defp supported?, do: JS.typeof(hid()) == "object"

  # An iframe without allow="hid" (Chrome's document.featurePolicy says).
  defp allowed? do
    policy = JS.get(:document, :featurePolicy)
    JS.typeof(policy) != "object" or JS.call(policy, :allowsFeature, ["hid"]) == true
  end

  defp opened?(device), do: JS.get(device, :opened) == true
  defp hid, do: JS.get(:navigator, :hid)
  defp deck, do: JS.get(:window, :clawswapDeck)
  defp known?(device), do: Map.has_key?(@models, JS.get(device, :productId))

  defp listen_for_plugging do
    if JS.get(:window, :clawswapPlugging) != true do
      JS.set(:window, :clawswapPlugging, true)
      JS.call(hid(), :addEventListener, ["connect", fn _event -> dispatch("reconnect", %{}) end])
      JS.call(hid(), :addEventListener, ["disconnect", fn _event -> dispatch("gone", %{}) end])
    end
  end

  defp dispatch(action, params), do: JS.call(:Hologram, :dispatchAction, [action, "stream_deck", params])

  defp open(component, device) do
    {name, count, size} = @models[JS.get(device, :productId)]
    if not opened?(device), do: device |> JS.call(:open, []) |> Task.await()
    JS.set(:window, :clawswapDeck, device)

    if JS.get(device, :clawswapListening) != true do
      JS.set(device, :clawswapListening, true)

      # Report 1: three bytes, then one byte for each key.
      JS.call(device, :addEventListener, [
        "inputreport",
        fn event ->
          if JS.get(event, :reportId) == 1 do
            data = JS.get(event, :data)
            dispatch("keys", %{keys: Enum.map(0..(count - 1), &JS.call(data, :getUint8, [3 + &1])), at: JS.call(:Date, :now, [])})
          end
        end
      ])
    end

    component
    |> put_state(model: name, count: count, size: size, sent: %{}, pressed: [], holds: %{}, message: nil)
    |> draw()
  end

  # Sends the keys whose image changed since they were last sent.
  defp draw(component) do
    %{count: count, size: size, sent: sent} = component.state
    images = component.state.keys |> key_images(count) |> Enum.with_index()

    case send_images(deck(), images, size, sent) do
      :lost -> put_state(component, model: nil, sent: %{}, pressed: [])
      sent -> put_state(component, :sent, sent)
    end
  end

  # A recursion rather than Enum.reduce/3: on the client, a function that awaits (send_image/4 does)
  # has to be a named one for its callers to wait for it.
  defp send_images(_device, [], _size, sent), do: sent

  defp send_images(device, [{image, key} | rest], size, sent) do
    cond do
      # Unplugged: it says so before the disconnect event comes.
      not opened?(device) ->
        :lost

      Map.has_key?(sent, key) and sent[key] == image ->
        send_images(device, rest, size, sent)

      true ->
        send_image(device, key, image, size)
        send_images(device, rest, size, Map.put(sent, key, image))
    end
  end

  defp send_image(device, key, image, size) do
    canvas = JS.new(:OffscreenCanvas, [size, size])
    context = JS.call(canvas, :getContext, ["2d"])
    JS.set(context, :fillStyle, "#000000")
    JS.call(context, :fillRect, [0, 0, size, size])

    if image do
      img = JS.new(:Image, [])
      JS.set(img, :src, image)
      img |> JS.call(:decode, []) |> Task.await()
      # These decks show their images upside down.
      JS.call(context, :setTransform, [-1, 0, 0, -1, size, size])
      JS.call(context, :drawImage, [img, 0, 0, size, size])
    end

    blob = canvas |> JS.call(:convertToBlob, [%{type: "image/jpeg", quality: 0.9}]) |> Task.await()
    jpeg = JS.new(:Uint8Array, [blob |> JS.call(:arrayBuffer, []) |> Task.await()])
    send_pages(device, key, jpeg, JS.get(jpeg, :length), 0)
  end

  # Header: 7, the key, 1 on the last page, the page's length and its number (both little-endian).
  defp send_pages(device, key, jpeg, length, page) do
    offset = page * (@report_bytes - @header_bytes)
    n = min(@report_bytes - @header_bytes, length - offset)
    last = if offset + n >= length, do: 1, else: 0
    report = JS.new(:Uint8Array, [@report_bytes])
    JS.call(report, :set, [[7, key, last, rem(n, 256), div(n, 256), rem(page, 256), div(page, 256)]])
    JS.call(report, :set, [JS.call(jpeg, :subarray, [offset, offset + n]), @header_bytes])
    device |> JS.call(:sendReport, [2, report]) |> Task.await()
    if last == 0, do: send_pages(device, key, jpeg, length, page + 1)
  end
end
