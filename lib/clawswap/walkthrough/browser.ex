defmodule Clawswap.Walkthrough.Browser do
  @moduledoc """
  The Chrome a walkthrough drives, through chromedriver with Wallaby. It's held for the process that
  started it (a walkthrough's, or a test's), so the script's commands need no session argument.

  It's visible unless asked otherwise, or there's no display to show it on (a Linux box without DISPLAY or
  WAYLAND_DISPLAY, such as a CI runner or Claude's cloud session), where it runs headless.
  CLAWSWAP_HEADLESS=1 or 0 and CLAWSWAP_SLOW (ms) override the options. CLAWSWAP_CHROME and
  CLAWSWAP_CHROMEDRIVER name the binaries when they aren't on the PATH; Chrome and chromedriver have to
  be the same major version.

  When a dev Chrome is open (`clawswap browser` starts one: its own profile, with a debugging port), a
  visible walkthrough plays in a tab of it instead of a window of its own, and keeps that tab for the next
  one. CLAWSWAP_CHROME_DEBUGGER names another one's address (host:port), or `off`.

  Nothing here knows about clawswap's other parts, so it could stand on its own.
  """

  @key :clawswap_walkthrough
  # Where `clawswap browser` opens Chrome's debugging port (not 9222, which editors' debuggers use).
  @dev_port 9333

  def dev_port, do: @dev_port

  @doc """
  Opens Chrome for this process. Options: `headless` (default: when there's no display), `slow` (ms to
  wait before each action, and twice that after a caption; default 600 when visible, 0 headless),
  `project` (for `Script.url/2`), `on_step` (called with each caption), `size` ({width, height}).
  Returns `{:ok, %{session, headless, slow}}` or `{:error, message}`.
  """
  def start(opts \\ []) do
    headless =
      case env_flag("CLAWSWAP_HEADLESS") do
        nil -> Keyword.get_lazy(opts, :headless, &no_display?/0)
        flag -> flag
      end

    slow = env_int("CLAWSWAP_SLOW") || Keyword.get(opts, :slow) || if(headless, do: 0, else: 600)
    {width, height} = Keyword.get(opts, :size, {1280, 900})

    dev = if not headless and Keyword.get(opts, :dev_chrome, true), do: dev_chrome()

    capabilities =
      if dev,
        do: %{javascriptEnabled: true, takesScreenshot: true, unhandledPromptBehavior: "accept", chromeOptions: %{debuggerAddress: dev, args: []}},
        else: capabilities(headless, width, height)

    with :ok <- start_wallaby(),
         {:ok, session} <- Wallaby.start_session(capabilities: capabilities),
         :ok <- if(dev, do: use_tab(session, dev), else: :ok) do
      state = %{session: session, headless: headless, slow: slow, project: opts[:project], on_step: opts[:on_step], caption: nil, frames: 0, dev: dev}
      Process.put(@key, state)
      {:ok, state}
    else
      {:error, %{message: message}} -> {:error, message}
      {:error, reason} -> {:error, "Couldn't start Chrome: #{inspect(reason)}"}
    end
  end

  @doc """
  The address of the dev Chrome to play walkthroughs in: CLAWSWAP_CHROME_DEBUGGER, or the one
  `clawswap browser` opens when it's running. nil when there's none.
  """
  def dev_chrome do
    case System.get_env("CLAWSWAP_CHROME_DEBUGGER") do
      off when off in ["off", "0", "false"] -> nil
      address when address not in [nil, ""] -> address
      _ -> if debugger?("127.0.0.1:#{@dev_port}"), do: "127.0.0.1:#{@dev_port}"
    end
  end

  @doc "Whether a Chrome answers on that debugging address."
  def debugger?(address) do
    :inets.start()
    match?({:ok, {{_, 200, _}, _, _}}, :httpc.request(:get, {~c"http://#{address}/json/version", []}, [timeout: 1000, connect_timeout: 500], []))
  end

  @doc """
  Opens a dev Chrome: a window with its own profile (kept in `profile`) and a debugging port, at `url`.
  Chrome only opens the port on a profile other than your everyday one. Returns the address, or
  `{:error, message}`.
  """
  def open_dev_chrome(profile, url) do
    address = "127.0.0.1:#{@dev_port}"

    cond do
      debugger?(address) ->
        {:ok, address}

      true ->
        configure()

        case Wallaby.Chrome.find_chrome_executable() do
          {:ok, chrome} ->
            File.mkdir_p!(profile)

            args =
              ["--remote-debugging-port=#{@dev_port}", "--user-data-dir=#{profile}", "--no-first-run", "--no-default-browser-check"] ++
                if(root?(), do: ["--no-sandbox"], else: []) ++ [url]

            # In the background, so it outlives this command.
            System.cmd("sh", ["-c", ~s(nohup "$0" "$@" >/dev/null 2>&1 &), chrome | args])

            started =
              Enum.any?(1..40, fn _ ->
                Process.sleep(250)
                debugger?(address)
              end)

            if started,
              do: {:ok, address},
              else: {:error, "Chrome started, but its debugging port #{@dev_port} didn't open"}

          {:error, %{message: message}} ->
            {:error, message}
        end
    end
  end

  # A walkthrough in the dev Chrome plays in a tab of its own, the same one each time while it's open (the
  # watcher's walkthroughs and clawswap walk's alike, so it's noted in a file), and your other tabs stay as
  # they are.
  defp use_tab(session, address) do
    note = Path.join(System.tmp_dir!(), "clawswap-tab-" <> String.replace(address, ~r/[^\w.-]/, "_"))
    open = with {:ok, list} when is_list(list) <- Wallaby.WebdriverClient.window_handles(session), do: list, else: (_ -> [])

    tab =
      case File.read(note) do
        {:ok, tab} -> if tab in open, do: tab
        _ -> nil
      end

    tab =
      tab ||
        case Wallaby.HTTPClient.request(:post, "#{session.session_url}/window/new", %{type: "tab"}) do
          {:ok, %{"value" => %{"handle" => handle}}} -> handle
          _ -> nil
        end

    if tab do
      File.write!(note, tab)
      {:ok, _} = Wallaby.WebdriverClient.focus_window(session, tab)
      Wallaby.HTTPClient.request(:post, "#{session.session_url}/goog/cdp/execute", %{cmd: "Page.bringToFront", params: %{}})
    end

    :ok
  end

  @doc "Closes this process's Chrome."
  def stop do
    case Process.delete(@key) do
      %{session: session} -> stop(session)
      nil -> :ok
    end
  end

  @doc "Closes a session started elsewhere (a test's on_exit runs in another process)."
  def stop(%Wallaby.Session{} = session) do
    Wallaby.end_session(session)
  catch
    _, _ -> :ok
  end

  def state, do: Process.get(@key) || raise("No browser: start one with Clawswap.Walkthrough.Browser.start/1")
  def update(changes), do: Process.put(@key, Map.merge(state(), Map.new(changes)))
  def session, do: state().session
  def caption, do: Process.get(@key) && Process.get(@key).caption

  @doc "Saves a screenshot in the system's temp folder and returns its path (nil when there's no browser)."
  def screenshot(name) do
    case Process.get(@key) do
      %{session: session} ->
        path = Path.join(System.tmp_dir!(), "clawswap-#{name}-#{System.system_time(:second)}.png")

        try do
          File.write!(path, session.driver.take_screenshot(session))
          path
        rescue
          _ -> nil
        end

      nil ->
        nil
    end
  end

  @doc """
  Runs `source` in each page before the page's own scripts, from the next load on (Chrome's DevTools
  protocol): for stand-ins of browser APIs, such as a fake navigator.hid.
  """
  def before_load(source) do
    session = session()

    {:ok, _} =
      Wallaby.HTTPClient.request(:post, "#{session.session_url}/goog/cdp/execute", %{
        cmd: "Page.addScriptToEvaluateOnNewDocument",
        params: %{source: source}
      })

    :ok
  end

  @doc "An element as a script argument (chromedriver turns this into the DOM node)."
  def element_arg(%Wallaby.Element{id: id}), do: %{"ELEMENT" => id, "element-6066-11e4-a23f-4f8b7e1fe0a6" => id}

  defp start_wallaby do
    configure()

    case Application.ensure_all_started(:wallaby) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        case Wallaby.Chrome.validate() do
          {:error, %{message: message}} -> {:error, message}
          _ -> {:error, "Couldn't start chromedriver"}
        end
    end
  end

  defp configure do
    Application.put_env(:wallaby, :driver, Clawswap.Walkthrough.Driver)
    # A walkthrough reports its own failures; the page's console errors don't fail it.
    Application.put_env(:wallaby, :js_errors, false)
    Application.put_env(:wallaby, :js_logger, nil)
    # How long a command waits for what it looks for (a dev server coming back after a switch can be slow).
    Application.put_env(:wallaby, :max_wait_time, env_int("CLAWSWAP_WAIT") || 10_000)
    Application.put_env(:wallaby, :base_url, "")

    chromedriver =
      [path: System.get_env("CLAWSWAP_CHROMEDRIVER") || "chromedriver", binary: System.get_env("CLAWSWAP_CHROME")]
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

    Application.put_env(:wallaby, :chromedriver, chromedriver)
  end

  defp capabilities(headless, width, height) do
    # Chrome won't start as root without it (containers, CI).
    args =
      ["--window-size=#{width},#{height}", "--no-first-run", "--no-default-browser-check", "--disable-search-engine-choice-screen"] ++
        if(headless, do: ["--headless=new", "--disable-gpu"], else: []) ++
        if(root?(), do: ["--no-sandbox"], else: [])

    options = %{args: args}
    options = if binary = System.get_env("CLAWSWAP_CHROME"), do: Map.put(options, :binary, binary), else: options

    %{
      javascriptEnabled: true,
      takesScreenshot: true,
      cssSelectorsEnabled: true,
      unhandledPromptBehavior: "accept",
      loggingPrefs: %{browser: "DEBUG"},
      chromeOptions: options
    }
  end

  defp no_display? do
    match?({:unix, :linux}, :os.type()) and System.get_env("DISPLAY") in [nil, ""] and System.get_env("WAYLAND_DISPLAY") in [nil, ""]
  end

  defp root? do
    match?({:unix, _}, :os.type()) and match?({"0\n", 0}, System.cmd("id", ["-u"]))
  rescue
    _ -> false
  end

  defp env_flag(name) do
    case System.get_env(name) do
      v when v in ["1", "true", "yes"] -> true
      v when v in ["0", "false", "no"] -> false
      _ -> nil
    end
  end

  defp env_int(name) do
    case Integer.parse(System.get_env(name) || "") do
      {n, _} -> n
      :error -> nil
    end
  end
end
