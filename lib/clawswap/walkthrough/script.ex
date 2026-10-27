defmodule Clawswap.Walkthrough.Script do
  @moduledoc """
  The commands a walkthrough script uses. They're imported for it, and drive the browser
  `Clawswap.Walkthrough.Browser` opened for the script. Each one waits for what it looks for (10 s, or
  CLAWSWAP_WAIT ms; pass `timeout:` for longer), and fails the walkthrough with what it couldn't find.

      say "Open the Branches menu"
      visit url(:web)
      click "Branches"
      see "claude/new-heading"

  Where a string isn't precise enough, give a Wallaby query: `css/2`, `button/2`, `link/2`,
  `text_field/2`, `select/2`, `option/2`, `xpath/2`. `session/0` is the Wallaby session for anything else.
  """

  alias Wallaby.{Browser, Element, Query}
  alias Clawswap.Walkthrough.Browser, as: B

  defdelegate css(selector, opts \\ []), to: Query
  defdelegate xpath(selector, opts \\ []), to: Query
  defdelegate button(selector, opts \\ []), to: Query
  defdelegate link(selector, opts \\ []), to: Query
  defdelegate text_field(selector, opts \\ []), to: Query
  defdelegate select(selector, opts \\ []), to: Query
  defdelegate option(selector, opts \\ []), to: Query

  @doc "The Wallaby session, for what these commands don't cover."
  def session, do: B.session()

  @doc """
  Shows a caption over the page saying what comes next, and pauses on it (twice the slow-motion delay).
  Each caption is a step of the walkthrough: the page and the terminal follow them, and a failure says
  which one it was in.
  """
  def say(text) do
    B.update(caption: text)
    state = B.state()
    IO.puts("\e[35m[walkthrough]\e[0m #{text}")
    if state.on_step, do: state.on_step.(text)
    draw_caption()
    pause(state.slow * 2)
  end

  @doc """
  The address of one of the project's servers (the first with a port when no name is given), or of
  clawswap's own page with `:clawswap`, plus `path`.
  """
  def url(server \\ nil, path \\ "/")

  def url(path, "/") when is_binary(path), do: url(nil, path)

  def url(server, path) do
    project = B.state().project || raise "url/2 needs the project's config: run the walkthrough with clawswap walk"

    port =
      cond do
        server in [:clawswap, "clawswap"] ->
          project.port

        server == nil ->
          Enum.find_value(project.server_names, &project.servers[&1].port) || raise "None of the servers has a port"

        true ->
          (project.servers[to_string(server)] || raise("No server called #{server}")).port || raise "Server #{server} has no port"
      end

    "http://localhost:#{port}#{path}"
  end

  @doc "Opens a page: a full URL, or a path on the first server with a port (`url/1`)."
  def visit(address) do
    address = if String.starts_with?(address, "/"), do: url(address), else: address
    pause()
    Browser.visit(session(), address)
    draw_caption()
    :ok
  end

  # What a string given to click/1 can be: the visible text of one of these.
  @clickable "button, a, [role=button], [role=menuitem], [role=tab], summary, label"

  @doc """
  Clicks a button, link or similar by (part of) its text, or what a query finds, after showing where (the
  element is outlined while the browser is slowed down).
  """
  def click(target, opts \\ []) do
    element = find(target, opts)
    point_at(element)
    Element.click(element)
    :ok
  end

  @doc "Types `with:` into a text field or textarea, found by its label, id, name or placeholder, then leaves it (for change events)."
  def fill_in(field, opts) do
    value = Keyword.fetch!(opts, :with)
    element = find(if(is_binary(field), do: Query.fillable_field(field), else: field), opts)
    point_at(element)
    Element.fill_in(element, with: value)
    Element.send_keys(element, [:tab])
    :ok
  end

  @doc "Picks `option` (its text) in a select found by its label, id or name."
  def choose(field, option, opts \\ []) do
    select = find(if(is_binary(field), do: Query.select(field), else: field), opts)
    point_at(select)
    select |> Browser.find(Query.option(option)) |> Element.click()
    :ok
  end

  @doc "Presses keys on the page: a string, or a list of strings and Wallaby key atoms (`:enter`, `:escape`...)."
  def press(keys) do
    pause()
    Browser.send_keys(session(), List.wrap(keys))
    :ok
  end

  @doc "Waits until the page shows `text`, or what a query finds, and fails if it doesn't. `timeout:` in ms."
  def see(target, opts \\ [])

  def see(text, opts) when is_binary(text) do
    wait_until(fn -> String.contains?(page_text(), text) end, Keyword.put_new(opts, :message, "Didn't see \"#{text}\""))
    :ok
  end

  def see(%Query{} = query, opts) do
    wait_until(fn -> Browser.has?(session(), query) end, Keyword.put_new(opts, :message, "Didn't find #{describe(query)}"))
    :ok
  end

  @doc "Waits until the page no longer shows `text` (or what a query finds)."
  def refute_see(target, opts \\ [])

  def refute_see(text, opts) when is_binary(text) do
    wait_until(fn -> not String.contains?(page_text(), text) end, Keyword.put_new(opts, :message, "Still seeing \"#{text}\""))
    :ok
  end

  def refute_see(%Query{} = query, opts) do
    wait_until(fn -> not Browser.has?(session(), query) end, Keyword.put_new(opts, :message, "Still finding #{describe(query)}"))
    :ok
  end

  @doc """
  Runs `fun` inside an iframe (a CSS selector or query), as when the page embeds another; the commands in
  it act on the frame's page.
  """
  def in_frame(frame, fun) do
    query = if is_binary(frame), do: Query.css(frame), else: frame
    find(query, [])
    Browser.focus_frame(session(), query)
    B.update(frames: B.state().frames + 1)

    try do
      fun.()
    after
      B.update(frames: B.state().frames - 1)
      Browser.focus_parent_frame(session())
    end
  end

  @doc "Runs JavaScript in the page and returns its value (`return ...`); `args` are its arguments[]."
  def js(source, args \\ []) do
    Browser.execute_script(session(), source, args, fn value -> send(self(), {:js, value}) end)

    receive do
      {:js, value} -> value
    after
      0 -> nil
    end
  end

  @doc "Runs JavaScript in every page from the next load on, before the page's own: for stand-ins of browser APIs."
  defdelegate before_load(source), to: B

  @doc "Waits until `check` returns something truthy (and returns it). Options: `timeout` (ms), `message`."
  def wait_until(check, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:wallaby, :max_wait_time, 10_000))
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(check, deadline, opts[:message] || "Timed out after #{timeout} ms")
  end

  defp poll(check, deadline, message) do
    result =
      try do
        check.()
      rescue
        _ -> nil
      end

    cond do
      result -> result
      System.monotonic_time(:millisecond) > deadline -> raise message
      true -> Process.sleep(150) && poll(check, deadline, message)
    end
  end

  @doc "Waits `ms`, or the slow-motion delay."
  def pause(ms \\ nil) do
    ms = ms || B.state().slow
    if ms > 0, do: Process.sleep(ms)
    :ok
  end

  @doc "Saves a screenshot and returns its path."
  def screenshot(name \\ "walkthrough"), do: B.screenshot(name)

  defp describe(%Query{method: method, selector: selector, conditions: conditions}) do
    text = if conditions[:text], do: " with text \"#{conditions[:text]}\"", else: ""
    "#{method} #{inspect(selector)}#{text}"
  end

  # What the page says, frames aside.
  defp page_text do
    session() |> Browser.find(Query.css("body")) |> Element.text()
  end

  defp find(text, opts) when is_binary(text), do: find(Query.css(@clickable, text: text, at: 0), opts)

  defp find(%Query{} = query, opts) do
    case opts[:timeout] do
      nil ->
        Browser.find(session(), query)

      timeout ->
        wait_until(fn -> Browser.has?(session(), query) end, timeout: timeout, message: "Didn't find #{describe(query)}")
        Browser.find(session(), query)
    end
  end

  # Scrolls to the element and, while slowed down, outlines it for a moment before the action.
  defp point_at(element) do
    state = B.state()

    if state.slow > 0 do
      Browser.execute_script(
        session(),
        """
        const el = arguments[0], ms = arguments[1];
        el.scrollIntoView({block: "center", inline: "nearest"});
        const before = [el.style.outline, el.style.outlineOffset];
        el.style.outline = "3px solid #f59e0b"; el.style.outlineOffset = "2px";
        setTimeout(() => { el.style.outline = before[0]; el.style.outlineOffset = before[1]; }, ms * 2);
        """,
        [B.element_arg(element), state.slow]
      )

      pause()
    end
  end

  # The caption, at the bottom of the page and letting clicks through. Not inside a frame, whose page is
  # usually too small for it.
  defp draw_caption do
    state = B.state()

    if state.caption && state.frames == 0 do
      Browser.execute_script(
        session(),
        """
        let c = document.getElementById("clawswap-caption");
        if (!c) {
          c = document.createElement("div");
          c.id = "clawswap-caption";
          c.style.cssText = "position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:2147483647;" +
            "max-width:80vw;padding:10px 18px;border-radius:8px;background:rgba(20,20,28,.88);color:#fff;" +
            "font:500 18px/1.35 system-ui,sans-serif;box-shadow:0 4px 18px rgba(0,0,0,.35);pointer-events:none";
          document.documentElement.appendChild(c);
        }
        c.textContent = arguments[0];
        """,
        [state.caption]
      )
    end

    :ok
  end
end
