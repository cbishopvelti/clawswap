defmodule ClawswapWeb.BranchesPage do
  @moduledoc """
  The watcher's page: the branches the keys show, a button for each that switches to it, and Pull. The
  watcher broadcasts each change, so the page follows a switch step by step.
  """

  use Hologram.Page

  alias Clawswap.Watcher
  alias ClawswapWeb.View

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
        <span class="webhook {@view.webhook_class}">{@view.webhook}</span>
        <button class="pull {@view.pull_class}" $click={command: :pull}>{@view.pull_label}</button>
      </header>
      {%if @message}<p class="message">{@message}</p>{/if}
      {%if @view.error}<p class="message">{@view.error}</p>{/if}
      <ul>
        {%for b <- @view.branches}
          <li class={b.class}>
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

  def action(:state_changed, params, component), do: put_state(component, :view, params.view)
  def action(:show_message, params, component), do: put_state(component, :message, params.message)

  def command(:switch, params, server), do: answer(server, Watcher.switch_to(params.branch))
  def command(:pull, _params, server), do: answer(server, Watcher.pull())

  defp answer(server, {:ok, _state}), do: put_action(server, :show_message, message: nil)
  defp answer(server, {:error, _status, message}), do: put_action(server, :show_message, message: message)
end
