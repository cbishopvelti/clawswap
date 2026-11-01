defmodule ClawswapWeb.BranchesPage do
  @moduledoc """
  The watcher's page: the branches the keys show, a button for each that switches to it, Pull, the
  checkout's walkthroughs (▶ runs one in a browser on this machine), and a link to the settings page (in a new window, as this page is often in an app's iframe). The watcher
  broadcasts each change, so the page follows a switch step by step. A click shows the switch (or pull)
  running at once, with a spinner, before the server has heard of it; the watcher's next broadcast takes over.
  """

  use Hologram.Page

  alias Clawswap.Watcher
  alias ClawswapWeb.{StreamDeck, View}

  route("/")

  layout(ClawswapWeb.MainLayout)

  def init(_params, component, server) do
    {put_state(component, view: View.page(Watcher.state()), message: nil), put_subscription(server, :clawswap)}
  end

  def template do
    ~HOLO"""
    <main>
      <header>
        <h1>{@view.project}</h1>
        {%if @view.on}<span class="on" title="The branch checked out now">On <strong>{@view.on}</strong></span>{/if}
        <span class="webhook {@view.webhook_class}">{@view.webhook}</span>
        <button class="pull {@view.pull_class}" $click={action: :pull}>{%if @view.pull_class == "running"}<span class="spinner"></span>{/if}{@view.pull_label}</button>
        <a class="settings-link" href="/settings" target="_blank" rel="noopener" title="Edit the config, in a new window">⚙</a>
        <StreamDeck cid="stream_deck" keys={@view.keys} />
      </header>
      {%if @message}<p class="message">{@message}</p>{/if}
      {%if @view.error}<p class="message">{@view.error}</p>{/if}
      {%if @view.walkthroughs != []}
        <section class="walks">
          <span class="walks-label" title="Scripts that drive a browser through the branch's changes">Walkthroughs</span>
          {%for w <- @view.walkthroughs}
            <button class="walk {w.class}" title={w.title} $click={command: :walk, params: %{name: w.name}}>▶ {w.name}</button>
          {/for}
          {%if @view.walk.text}<span class="walk-status {@view.walk.class}">{@view.walk.text}</span>{/if}
        </section>
      {/if}
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
    """
  end

  def action(:state_changed, params, component) do
    component
    |> put_state(:view, params.view)
    |> put_action(name: :draw, target: "stream_deck", params: %{keys: params.view.keys})
  end

  def action(:show_message, params, component), do: put_state(component, :message, params.message)

  # A click: show it running now, then ask the server.
  def action(:switch, params, component) do
    action(:switching, params, component)
    |> put_command(:switch, branch: params.branch)
  end

  def action(:pull, params, component) do
    action(:switching, params, component)
    |> put_command(:pull)
  end

  # What a switch to `branch` (or a pull, with no branch) shows until the watcher says where it's got to.
  # The Stream Deck's keys send this too. Nothing changes while one is running: the watcher will refuse it.
  def action(:switching, params, component) do
    view = component.state.view

    cond do
      view.busy ->
        component

      Map.get(params, :branch) ->
        branches = Enum.map(view.branches, &if(&1.branch == params.branch, do: switching(&1, view.current), else: &1))
        put_state(component, :view, %{view | busy: true, branches: branches})

      true ->
        put_state(component, :view, %{view | busy: true, pull_class: "running", pull_label: "Pulling: ..."})
    end
  end

  defp switching(row, current), do: %{row | class: "running", row_class: if(row.branch == current, do: "running checkout", else: "running"), status: "Switching"}

  def command(:switch, params, server), do: answer(server, Watcher.switch_to(params.branch))
  def command(:pull, _params, server), do: answer(server, Watcher.pull())
  def command(:walk, params, server), do: answer(server, Watcher.walk(params.name))

  defp answer(server, {:ok, _state}), do: put_action(server, :show_message, message: nil)
  defp answer(server, {:error, _status, message}), do: put_action(server, :show_message, message: message)
end
