defmodule ClawswapWeb.DebugPanel do
  @moduledoc """
  The debug panel, docked on the right of every clawswap page (`ClawswapWeb.MainLayout`): a Chrome driven
  through chromedriver that stays open while you work (`Clawswap.Walkthrough.Debugger`). Open it, run the project's walkthroughs (▶ to the end, ⏯ a caption
  at a time, with Step, Continue and Stop at each pause), type walkthrough commands into it, switch
  between its tabs, and see a screenshot after each thing it does. 🐞 folds it away and back; it's hidden
  on narrow pages (the branch page in an app's dropdown). `ClawswapWeb.PanelPage` (/panel) shows it on its
  own, for an app to frame in a sidebar of its own (`foldable` false: the app folds its sidebar).
  """

  use Hologram.Component

  alias Clawswap.Walkthrough.{Browser, Debugger}
  alias ClawswapWeb.DebugView

  prop(:foldable, :boolean, default: true)

  @placeholder ~s|click "Ping"  ·  see "pong"  ·  visit url(:web)  ·  js "return document.title"|

  def init(_props, component, server) do
    view = DebugView.page(Debugger.state())
    component = put_state(component, view: view, message: nil, code: "", headless: Browser.headless?(), placeholder: @placeholder, open: true)
    {component, put_subscription(server, :clawswap_debug)}
  end

  def template do
    ~HOLO"""
    <aside class="debug {if @open do "open" else "folded" end}">
      {%if @foldable}
        <button class="fold" title={if @open do "Fold the debug panel away" else "Open the debug panel" end} $click="fold">🐞</button>
      {/if}
      {%if @open}
      <header>
        <h1>Chrome</h1>
        <span class="browser {@view.browser}">{@view.browser_label}</span>
        {%if @view.closed}
          <label class="headless" title="Without a window: you follow it in the screenshots here">
            <input type="checkbox" checked={@headless} $change="set_headless" /> Headless
          </label>
          <button class="primary" $click={command: :open, params: %{headless: @headless}}>Open Chrome</button>
        {%else}
          <button $click={command: :refresh} title="Take a new screenshot and look at the tabs again">↻ Screenshot</button>
          <button $click={command: :close}>Close Chrome</button>
        {/if}
      </header>
      {%if @message}<p class="message dmessage">{@message}</p>{/if}
      {%if @view.walkthroughs != []}
        <section class="dwalks">
          <span class="walks-label" title="▶ runs one to the end; ⏯ pauses at each caption">Walkthroughs</span>
          {%for w <- @view.walkthroughs}
            <span class="walk-pair">
              <span class="name">{w}</span>
              <button class="dwalk run" title="Run to the end" $click={command: :walk, params: %{name: w, step: false}}>▶</button>
              <button class="dwalk step" title="Run a caption at a time" $click={command: :walk, params: %{name: w, step: true}}>⏯</button>
            </span>
          {/for}
          {%if @view.paused}
            <span class="controls">
              <button class="primary" $click={command: :resume, params: %{how: "step"}}>Step</button>
              <button $click={command: :resume, params: %{how: "continue"}}>Continue</button>
              <button $click={command: :resume, params: %{how: "stop"}}>Stop</button>
            </span>
          {/if}
          {%if @view.running}<span class="controls"><button $click={command: :pause}>Pause</button></span>{/if}
          {%if @view.walk.text}<span class="dwalk-status {@view.walk.class}">{@view.walk.text}</span>{/if}
        </section>
      {/if}
      <form class="command" $submit="run">
        <input name="code" type="text" value={@code} $input="typed" autocomplete="off" spellcheck="false"
          placeholder={@placeholder} />
        <button type="submit">Run</button>
      </form>
      {%if @view.servers != []}
        <section class="visit">
          <span class="walks-label">Visit</span>
          {%for s <- @view.servers}
            <button class="dwalk" $click={command: :run, params: %{code: "visit url(:#{s})"}}>{s}</button>
          {/for}
          {%if @view.url}<span class="url">{@view.url}</span>{/if}
        </section>
      {/if}
      {%if @view.tabs != []}
        <section class="tabs">
          {%for t <- @view.tabs}
            <button class={t.class} title={t.url} $click={command: :tab, params: %{handle: t.handle}}>{t.label}</button>
          {/for}
          <button class="tab" title="Open a new tab" $click={command: :tab, params: %{handle: "new"}}>+</button>
          <button class="tab" title="Close this tab" $click={command: :tab, params: %{handle: "close"}}>✕</button>
        </section>
      {/if}
      <div class="debug-body">
        <div class="shot">
          {%if @view.shot}
            <img src={@view.shot} alt="Chrome, after the last thing it did" />
          {%else}
            <p class="about">A screenshot shows here after each command.</p>
          {/if}
        </div>
        <ol class="log">
          {%for l <- @view.log}
            {%if l.kind == "command"}
              <li class={l.kind} title="Click to run it again" $click={action: :reuse, params: %{code: l.text}}>{l.text}</li>
            {%else}
              <li class={l.kind}>{l.text}</li>
            {/if}
          {/for}
        </ol>
      </div>
      {/if}
    </aside>
    """
  end

  def action(:debug_changed, params, component), do: put_state(component, :view, params.view)

  def action(:fold, _params, component), do: put_state(component, :open, !component.state.open)

  def action(:show_message, params, component), do: put_state(component, :message, params.message)

  def action(:set_headless, params, component), do: put_state(component, :headless, params.event.value)

  def action(:typed, params, component), do: put_state(component, :code, params.event.value)

  def action(:reuse, params, component), do: put_state(component, :code, params.code)

  def action(:run, params, component) do
    code = Map.get(params.event, "code", component.state.code)

    component
    |> put_state(:code, "")
    |> put_command(:run, code: code)
  end

  def command(:open, params, server), do: answer(server, Debugger.open(headless: params.headless))
  def command(:close, _params, server), do: answer(server, Debugger.close())
  def command(:refresh, _params, server), do: answer(server, Debugger.refresh())
  def command(:run, params, server), do: answer(server, Debugger.run(params.code))
  def command(:walk, params, server), do: answer(server, Debugger.walk(params.name, step: params.step))
  def command(:pause, _params, server), do: answer(server, Debugger.pause())

  def command(:resume, params, server) do
    how = Map.fetch!(%{"step" => :step, "continue" => :continue, "stop" => :stop}, params.how)
    answer(server, Debugger.resume(how))
  end

  def command(:tab, params, server) do
    which =
      case params.handle do
        "new" -> :new
        "close" -> :close
        handle -> handle
      end

    answer(server, Debugger.tab(which))
  end

  defp answer(server, {:ok, _view}), do: put_action(server, name: :show_message, target: "debug_panel", params: %{message: nil})
  defp answer(server, {:error, _status, message}), do: put_action(server, name: :show_message, target: "debug_panel", params: %{message: message})
end
