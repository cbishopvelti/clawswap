defmodule ClawswapWeb.BranchesPage do
  @moduledoc """
  The watcher's page: the branches the keys show, a button for each that switches to it, Pull, and a link
  to the settings page (in a new window, as this page is often in an app's iframe). The watcher
  broadcasts each change, so the page follows a switch step by step.
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
        <button class="pull {@view.pull_class}" $click={command: :pull}>{@view.pull_label}</button>
        <a class="settings-link" href="/settings" target="_blank" rel="noopener" title="Edit the config, in a new window">⚙</a>
        <StreamDeck cid="stream_deck" keys={@view.keys} />
      </header>
      {%if @message}<p class="message">{@message}</p>{/if}
      {%if @view.error}<p class="message">{@view.error}</p>{/if}
      <ul>
        {%for b <- @view.branches}
          <li class={b.row_class}>
            <button $click={command: :switch, params: %{branch: b.branch}}>
              <span class="mark {b.mark_class}" title={b.mark_title}>{b.mark}</span>
              {%if b.number}<span class="number">{b.number}</span>{/if}
              <span class="title">{b.title}</span>
              <span class="status">{b.status}</span>
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

  def command(:switch, params, server), do: answer(server, Watcher.switch_to(params.branch))
  def command(:pull, _params, server), do: answer(server, Watcher.pull())

  defp answer(server, {:ok, _state}), do: put_action(server, :show_message, message: nil)
  defp answer(server, {:error, _status, message}), do: put_action(server, :show_message, message: message)
end
