defmodule Clawswap.Walkthrough.Browser do
  @moduledoc """
  The Chrome a walkthrough drives, through chromedriver with Wallaby. It's held for the process that
  started it (a walkthrough's, or a test's), so the script's commands need no session argument.

  It's visible unless asked otherwise, or there's no display to show it on (a Linux box without DISPLAY or
  WAYLAND_DISPLAY, such as a CI runner or Claude's cloud session), where it runs headless.
  CLAWSWAP_HEADLESS=1 or 0 and CLAWSWAP_SLOW (ms) override the options. CLAWSWAP_CHROME and
  CLAWSWAP_CHROMEDRIVER name the binaries when they aren't on the PATH; Chrome and chromedriver have to
  be the same version.

  Nothing here knows about clawswap's other parts, so it could stand on its own.
  """

  @key :clawswap_walkthrough

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

    with :ok <- start_wallaby(),
         {:ok, session} <- Wallaby.start_session(capabilities: capabilities(headless, width, height)) do
      state = %{session: session, headless: headless, slow: slow, project: opts[:project], on_step: opts[:on_step], caption: nil, frames: 0}
      Process.put(@key, state)
      {:ok, state}
    else
      {:error, %{message: message}} -> {:error, message}
      {:error, reason} -> {:error, "Couldn't start Chrome: #{inspect(reason)}"}
    end
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
    Application.put_env(:wallaby, :driver, Wallaby.Chrome)
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
