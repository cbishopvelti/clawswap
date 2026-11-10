defmodule ClawswapWeb.SettingsPage do
  @moduledoc """
  The config editor, opened in its own window from the branch page's Settings link. It edits the
  project's clawswap.exs or clawswap.yml (see `Clawswap.Config.Form`), and a save restarts the watcher on
  the new config.
  """

  use Hologram.Page

  alias Clawswap.Config.Form
  alias Clawswap.Watcher

  route("/p/:project/settings")
  param(:project, :string)

  layout(ClawswapWeb.MainLayout)

  def init(params, component, _server) do
    put_state(component, Map.merge(%{id: params.project, schema: Form.schema(), message: nil, error: nil, saving: false}, form(params.project)))
  end

  defp form(id) do
    case Clawswap.Projects.get(id) do
      nil ->
        %{file: "", format: "", values: %{}, code: %{}, rows: %{}, next: 1, load_error: "No project #{id} (clawswap up starts it)"}

      project ->
        case Form.load(project) do
          {:ok, form} -> Map.put(form, :load_error, nil)
          {:error, message} -> %{file: project.file, format: "", values: %{}, code: %{}, rows: %{}, next: 1, load_error: message}
        end
    end
  end

  def template do
    ~HOLO"""
    <main class="settings">
      <header>
        <h1>Settings</h1>
        <span class="file">{@file}</span>
      </header>
      {%if @load_error}
        <p class="message">{@load_error}</p>
      {%else}
        <form $submit="submit">
          <section>
            {%for f <- @schema.general}
              <label class="field {if f.wide do "wide" end}">
                <span class="name">{f.label}</span>
                {%if f.options != []}
                  <select value={Map.get(@values, f.key, "")} $change={action: :set, params: %{id: f.key}}>
                    <option value="">{f.hint}</option>
                    {%for o <- f.options}<option value={o}>{o}</option>{/for}
                  </select>
                {%else}
                  {%if f.wide or Map.has_key?(@code, f.key)}
                    <textarea class={if Map.has_key?(@code, f.key) do "code" end} rows="2" placeholder={f.hint}
                      value={Map.get(@values, f.key, "")} $change={action: :set, params: %{id: f.key}} />
                  {%else}
                    <input type="text" placeholder={f.hint} value={Map.get(@values, f.key, "")} $change={action: :set, params: %{id: f.key}} />
                  {/if}
                {/if}
              </label>
            {/for}
          </section>
          {%for s <- @schema.sections}
            <section>
              <h2>{s.label}</h2>
              <p class="about">{s.about}</p>
              {%if Map.has_key?(@code, s.key <> "._code")}
                <textarea class="code" rows="6" value={Map.get(@values, s.key <> "._code", "")}
                  $change={action: :set, params: %{id: s.key <> "._code"}} />
              {%else}
                {%for r <- Map.get(@rows, s.key, [])}
                  <div class="row">
                    {%if s.named}
                      <label class="field">
                        <span class="name">Name</span>
                        <input type="text" value={Map.get(@values, "#{s.key}.#{r.id}._name", "")}
                          $change={action: :set, params: %{id: "#{s.key}.#{r.id}._name"}} />
                      </label>
                    {/if}
                    {%for f <- s.fields}
                      <label class="field {if f.wide do "wide" end} {if f.long do "long" end}">
                        <span class="name">{f.label}</span>
                        {%if f.wide or Map.has_key?(@code, "#{s.key}.#{r.id}.#{f.key}")}
                          <textarea class={if Map.has_key?(@code, "#{s.key}.#{r.id}.#{f.key}") do "code" end} rows="2"
                            placeholder={f.hint} value={Map.get(@values, "#{s.key}.#{r.id}.#{f.key}", "")}
                            $change={action: :set, params: %{id: "#{s.key}.#{r.id}.#{f.key}"}} />
                        {%else}
                          <input type="text" placeholder={f.hint} value={Map.get(@values, "#{s.key}.#{r.id}.#{f.key}", "")}
                            $change={action: :set, params: %{id: "#{s.key}.#{r.id}.#{f.key}"}} />
                        {/if}
                      </label>
                    {/for}
                    <div class="row-buttons">
                      <button type="button" title="Move up" $click={action: :move_up, params: %{section: s.key, id: r.id}}>↑</button>
                      <button type="button" title="Remove" $click={action: :remove, params: %{section: s.key, id: r.id}}>✕</button>
                    </div>
                  </div>
                {/for}
                <button type="button" class="add" $click={action: :add, params: %{section: s.key}}>+ Add</button>
              {/if}
            </section>
          {/for}
          <footer>
            <button type="submit" class="save" disabled={@saving}>{if @saving do "Saving..." else "Save" end}</button>
            {%if @error}<span class="message">{@error}</span>{/if}
            {%if @message}<span class="saved">{@message}</span>{/if}
          </footer>
          <p class="about">
            {%if @format == "yaml"}
              Saving writes {@file} afresh, so comments in it are lost.
            {%else}
              Saving changes only the settings you changed: comments and the Elixir in {@file} stay as they are, and the
              file is formatted as mix format would.
            {/if}
            Fields in monospace are Elixir. In When, a line written /like this/ is a regex. The watcher restarts
            to load a saved config; commit the change before switching branch, as a switch refuses uncommitted
            changes.
          </p>
        </form>
      {/if}
    </main>
    """
  end

  def action(:set, params, component) do
    put_state(component, :values, Map.put(component.state.values, params.id, params.event.value))
  end

  def action(:add, params, component) do
    row = %{id: "r#{component.state.next}", orig: nil}
    rows = Map.put(component.state.rows, params.section, Map.get(component.state.rows, params.section, []) ++ [row])
    put_state(component, rows: rows, next: component.state.next + 1)
  end

  def action(:remove, params, component) do
    rows = Enum.reject(Map.get(component.state.rows, params.section, []), fn r -> r.id == params.id end)
    put_state(component, :rows, Map.put(component.state.rows, params.section, rows))
  end

  def action(:move_up, params, component) do
    rows = Map.get(component.state.rows, params.section, [])
    i = Enum.find_index(rows, fn r -> r.id == params.id end)

    if i > 0 do
      {row, rest} = List.pop_at(rows, i)
      put_state(component, :rows, Map.put(component.state.rows, params.section, List.insert_at(rest, i - 1, row)))
    else
      component
    end
  end

  def action(:submit, _params, component) do
    %{values: values, code: code, rows: rows} = component.state

    component
    |> put_state(saving: true, message: nil, error: nil)
    |> put_command(:save, values: values, code: code, rows: rows, project: component.state.id)
  end

  def action(:saved, params, component), do: put_state(component, Map.put(params, :saving, false))

  def command(:save, params, server) do
    project = Clawswap.Projects.get(params.project)
    save = fn -> Form.save(project, Map.drop(params, [:project])) end

    case project && Watcher.save_config(Clawswap.Project.via(project.id, :watcher), save) do
      nil -> put_action(server, :saved, message: nil, error: "No project #{params.project} (clawswap up starts it)")
      # The rows now stand for what's in the file, for the next save.
      {:ok, :saved} -> put_action(server, :saved, Map.merge(form(project.id), %{message: "Saved. The project is restarting with it.", error: nil}))
      {:ok, :unchanged} -> put_action(server, :saved, message: "Nothing has changed.", error: nil)
      {:error, message} -> put_action(server, :saved, message: nil, error: message)
    end
  end
end
