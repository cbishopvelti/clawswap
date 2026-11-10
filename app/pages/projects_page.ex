defmodule ClawswapWeb.ProjectsPage do
  @moduledoc """
  The daemon's front page, /: every project it runs, the branch each is on and how its last switch went,
  with a link to its page (/p/<id>). "Select" makes one the selected project: the one Stream Deck keys
  that follow the selected project show, and that the API's paths without /p/<id> answer for. The Stream
  Deck can be connected here too.
  """

  use Hologram.Page

  alias ClawswapWeb.{StreamDeck, View}

  route("/")

  layout(ClawswapWeb.MainLayout)

  def init(_params, component, server) do
    {put_state(component, projects: View.index(), message: nil), put_subscription(server, :clawswap_index)}
  end

  def template do
    ~HOLO"""
    <main class="projects">
      <header>
        <h1>clawswap</h1>
        <StreamDeck cid="stream_deck" />
      </header>
      {%if @message}<p class="message">{@message}</p>{/if}
      {%if @projects == []}
        <p class="about">No projects yet: run <code>clawswap up</code> in a project's checkout.</p>
      {%else}
        <ul>
          {%for p <- @projects}
            <li class={p.class}>
              <a class="name" href={p.href} title={p.root}>{p.name}</a>
              <span class="on">{p.on}</span>
              <span class="status">{p.status}</span>
              {%if p.class == "project selected"}
                <span class="selected-mark" title="Stream Deck keys that follow the selected project show this one">selected</span>
              {%else}
                <button class="select" $click={command: :select, params: %{project: p.id}}>Select</button>
              {/if}
            </li>
          {/for}
        </ul>
      {/if}
    </main>
    """
  end

  def action(:projects_changed, params, component), do: put_state(component, :projects, params.projects)
  def action(:show_message, params, component), do: put_state(component, :message, params.message)

  def command(:select, params, server) do
    case Clawswap.Projects.select(params.project) do
      :ok -> put_action(server, :show_message, message: nil)
      {:error, message} -> put_action(server, :show_message, message: message)
    end
  end
end
