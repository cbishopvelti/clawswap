defmodule ClawswapWeb.BranchesPage do
  @moduledoc """
  A project's page, /p/<id>: the branches the keys show, a button for each that switches to it, Pull, the
  checkout's walkthroughs (▶ runs one in a browser on this machine), a link to the settings page (in a new window, as this page is often in an app's iframe). The watcher
  broadcasts each change, so the page follows a switch step by step. Switching, pulling or running a
  walkthrough here selects the project (`Clawswap.Projects.select/1`), so keys that follow the selected
  project show this one.
  """

  use Hologram.Page
  use Hologram.JS

  alias Clawswap.{Project, Projects, Watcher}
  alias ClawswapWeb.{DebugPanel, StreamDeck, View}

  route("/p/:project")
  param(:project, :string)

  layout(ClawswapWeb.MainLayout)

  def init(params, component, server) do
    id = params.project

    case Project.whereis(id, :watcher) do
      nil ->
        put_state(component, id: id, view: nil, message: nil)

      watcher ->
        {put_state(component, id: id, view: View.page(Watcher.state(watcher)), message: nil), put_subscription(server, {:clawswap, id})}
    end
  end

  def template do
    ~HOLO"""
    {%if @view == nil}
    <main>
      <header><h1>No project {@id}</h1></header>
      <p class="message">clawswap up, in that project's checkout, starts it. <a href="/">All projects</a></p>
    </main>
    {%else}
    <div class="with-panel">
    <div class="page">
    <main>
      <header>
        <a class="all-projects" href="/" title="All projects">☰</a>
        <h1>{@view.project}</h1>
        {%if @view.on}<span class="on" title="The branch checked out now">On <strong>{@view.on}</strong></span>{/if}
        <span class="webhook {@view.webhook_class}">{@view.webhook}</span>
        <button class="pull {@view.pull_class}" $click={command: :pull, params: %{project: @id}}>{@view.pull_label}</button>
        <a class="settings-link" href={"/p/#{@id}/settings"} target="_blank" rel="noopener" title="Edit the config, in a new window">⚙</a>
        <StreamDeck cid="stream_deck" />
      </header>
      {%if @message}<p class="message">{@message}</p>{/if}
      {%if @view.error}<p class="message">{@view.error}</p>{/if}
      {%if @view.walkthroughs != []}
        <section class="walks">
          <span class="walks-label" title="Scripts that drive a browser through the branch's changes">Walkthroughs</span>
          {%for w <- @view.walkthroughs}
            <button class="walk {w.class}" title={w.title} $click={command: :walk, params: %{name: w.name, project: @id}}>▶ {w.name}</button>
          {/for}
          {%if @view.walk.text}<span class="walk-status {@view.walk.class}">{@view.walk.text}</span>{/if}
        </section>
      {/if}
      <ul>
        {%for b <- @view.branches}
          <li class={b.row_class}>
            <button $click={command: :switch, params: %{branch: b.branch, project: @id}}>
              <span class="mark {b.mark_class}" title={b.mark_title}>{b.mark}</span>
              {%if b.number}<span class="number">{b.number}</span>{/if}
              <span class="title">{b.title}</span>
              <span class="status">{b.status}</span>
            </button>
          </li>
        {/for}
      </ul>
    </main>
    </div>
    <DebugPanel cid="debug_panel" project={@id} />
    </div>
    {/if}
    """
  end

  def action(:state_changed, params, component) do
    switched = params.view.switched
    if switched && switched != component.state.view.switched, do: tell_parent(switched)

    put_state(component, :view, params.view)
  end

  def action(:show_message, params, component), do: put_state(component, :message, params.message)

  def command(:switch, params, server), do: answer(server, Watcher.switch_to(watcher(params), params.branch))
  def command(:pull, params, server), do: answer(server, Watcher.pull(watcher(params)))
  def command(:walk, params, server), do: answer(server, Watcher.walk(watcher(params), params.name))

  # Using a project's page makes it the selected one.
  defp watcher(params) do
    Projects.select(params.project)
    Project.via(params.project, :watcher)
  end

  # When this page is in an app's iframe: a switch or pull finished (its servers are listening again), so
  # the app can reload. It's another origin (another port), so it can't reload the app itself; the app
  # listens for this instead (docs/page.html#reload). Outside a frame, parent is the page itself, and
  # nothing listens.
  defp tell_parent(switched) do
    # `:parent`, the global, rather than JS.get(:window, :parent): boxing another origin's window fails.
    JS.call(:parent, :postMessage, [%{clawswap: "switched", branch: switched.branch}, "*"])
  end

  defp answer(server, {:ok, _state}), do: put_action(server, :show_message, message: nil)
  defp answer(server, {:error, _status, message}), do: put_action(server, :show_message, message: message)
end
