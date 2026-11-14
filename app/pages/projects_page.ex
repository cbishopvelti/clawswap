defmodule ClawswapWeb.ProjectsPage do
  @moduledoc """
  The daemon's front page, /: every project it runs, the branch each is on and how its last switch went,
  with a link to its page (/p/<id>). "Select" makes one the selected project: the one Stream Deck keys
  that follow the selected project show, and that the API's paths without /p/<id> answer for. The Stream
  Deck can be connected here too.

  ☰ on a project's page comes here, and in an app's iframe there's no browser Back button, so the header
  links back to the project whose page you came from (the focused one, `Clawswap.Projects.focused/0`), and
  Escape goes back there too.
  """

  use Hologram.Page
  use Hologram.JS

  alias ClawswapWeb.{BranchesPage, StreamDeck, View}

  route("/")

  layout(ClawswapWeb.MainLayout)

  def init(_params, component, server) do
    projects = View.index()

    component =
      component
      |> put_state(projects: projects, back: back(projects), message: nil)
      |> put_action(:listen)

    {component, put_subscription(server, :clawswap_index)}
  end

  # The project whose page was last in view, if it's still running: where ← and Escape go.
  defp back(projects) do
    case Clawswap.Projects.focused() do
      %{project: id} -> Enum.find_value(projects, fn p -> if p.id == id, do: %{id: p.id, name: p.name, href: p.href} end)
      _ -> nil
    end
  end

  def template do
    ~HOLO"""
    <main class="projects">
      <header>
        {%if @back}<a class="back" href={@back.href} title="Back to {@back.name}'s page (Esc)">← {@back.name}</a>{/if}
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

  # On load: Escape goes back to the project's page. The listener stays when Hologram navigates without a
  # reload, so it's added once, and only acts while this page is the one showing.
  def action(:listen, _params, component) do
    if JS.get(:window, :clawswapEscape) != true do
      JS.set(:window, :clawswapEscape, true)

      JS.call(:document, :addEventListener, [
        "keydown",
        fn event ->
          if JS.get(event, :key) == "Escape" and JS.get(:location, :pathname) == "/",
            do: JS.call(:Hologram, :dispatchAction, ["back", "page", %{}])
        end
      ])
    end

    component
  end

  def action(:back, _params, component) do
    case component.state.back do
      %{id: id} -> put_page(component, BranchesPage, project: id)
      nil -> component
    end
  end

  def action(:projects_changed, params, component) do
    component = put_state(component, :projects, params.projects)
    # The project went down while this page showed: no way back to it.
    if component.state.back && not Enum.any?(params.projects, &(&1.id == component.state.back.id)),
      do: put_state(component, :back, nil),
      else: component
  end

  def action(:show_message, params, component), do: put_state(component, :message, params.message)

  def command(:select, params, server) do
    case Clawswap.Projects.select(params.project) do
      :ok -> put_action(server, :show_message, message: nil)
      {:error, message} -> put_action(server, :show_message, message: message)
    end
  end
end
