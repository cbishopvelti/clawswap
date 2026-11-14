defmodule ClawswapWeb.BranchesPage do
  @moduledoc """
  A project's page, /p/<id>: the branches the keys show, a button for each that switches to it, Pull, the
  checkout's walkthroughs (▶ runs one in a browser on this machine), a link to the settings page (in a new window, as this page is often in an app's iframe). The watcher
  broadcasts each change, so the page follows a switch step by step. Switching, pulling or running a
  walkthrough here selects the project (`Clawswap.Projects.select/1`), so keys that follow the selected
  project show this one.

  A click shows the switch (or pull) running at once, with a spinner, before the server has heard of it
  (`switching/2`, on the client); the watcher's broadcasts take over once one shows it running. A press
  of a Stream Deck key driven from this page does the same.
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
        put_state(component, id: id, view: nil, server: nil, pending: nil, message: nil)

      watcher ->
        view = View.page(Watcher.state(watcher))
        {put_state(component, id: id, view: view, server: view, pending: nil, message: nil), put_subscription(server, {:clawswap, id})}
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
        <span class="actions">
          <button class="pull {@view.pull_class}" title={@view.pull_title} disabled={@view.pull_class == "none"} $click={action: :pull}>{%if @view.pull_class == "running"}<span class="spinner"></span>{/if}{@view.pull_label}</button>
          <a class="settings-link" href={"/p/#{@id}/settings"} target="_blank" rel="noopener" title="Edit the config, in a new window">⚙</a>
        </span>
        <StreamDeck cid="stream_deck" page_project={@id} />
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
      {%if @view.empty}<p class="empty">{@view.empty}</p>{/if}
      <ul>
        {%for b <- @view.branches}
          <li class={b.row_class}>
            <button $click={action: :switch, params: %{branch: b.branch}}>
              <span class="mark {b.mark_class}" title={b.mark_title}>{b.mark}</span>
              {%if b.number}<span class="number">{b.number}</span>{/if}
              <span class="title">{b.title}</span>
              <span class="status">{%if b.class == "running"}<span class="spinner"></span>{/if}{b.status}</span>
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
    view = params.view
    switched = view.switched
    if switched && switched != component.state.server.switched, do: tell_parent(switched)

    follow(component, view)
  end

  # The answer to a click: a refusal ends its spinner (the message says why); otherwise the watcher's
  # broadcasts do, once one shows it.
  def action(:show_message, params, component) do
    component = put_state(component, :message, params.message)

    cond do
      component.state.pending == nil -> component
      params.message -> put_state(component, pending: nil, view: component.state.server)
      true -> follow(component, component.state.server)
    end
  end

  # A click: show it running now, then ask the server.
  def action(:switch, params, component) do
    :switching
    |> action(%{branch: params.branch}, component)
    |> put_command(:switch, branch: params.branch, project: component.state.id)
  end

  def action(:pull, _params, component) do
    :switching
    |> action(%{branch: nil}, component)
    |> put_command(:pull, project: component.state.id)
  end

  # What a switch to `branch` (or a pull, with branch nil) shows until the watcher says where it's got to.
  # A Stream Deck key pressed on this page sends this too. Nothing changes while one is running: the
  # watcher will refuse it.
  def action(:switching, params, component) do
    view = component.state.view

    if view.busy,
      do: component,
      else: put_state(component, view: switching(view, params), pending: Map.put(params, :since, component.state.server.run_at), message: nil)
  end

  # Shows the watcher's view, or a click's spinner over it while the watcher hasn't acted on the click
  # yet (its last switch is the one it had then): a broadcast sent before it heard of it mustn't hide it.
  defp follow(component, server) do
    pending = component.state.pending

    if pending && server.run_at == pending.since && !server.busy,
      do: put_state(component, server: server, view: switching(server, pending)),
      else: put_state(component, server: server, view: server, pending: nil)
  end

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

  defp switching(view, %{branch: nil}), do: %{view | busy: true, pull_class: "running", pull_label: "Pulling: ..."}

  defp switching(view, %{branch: branch}) do
    %{view | busy: true, branches: Enum.map(view.branches, &if(&1.branch == branch, do: switching_row(&1, view.current), else: &1))}
  end

  defp switching_row(row, current),
    do: %{row | class: "running", row_class: if(row.branch == current, do: "running checkout", else: "running"), status: "Switching"}

  defp answer(server, {:ok, _state}), do: put_action(server, :show_message, message: nil)
  defp answer(server, {:error, _status, message}), do: put_action(server, :show_message, message: message)
end
