defmodule Clawswap.Feature do
  @moduledoc """
  What a browser test (`clawswap test`, `Clawswap.BrowserTests`) uses: `use Clawswap.Feature` makes the
  module an ExUnit case with Wallaby's features, and `url/2` for the project's servers.

      defmodule ChatTest do
        use Clawswap.Feature, async: true

        feature "the app opens", %{session: session} do
          session
          |> visit(url(:web))
          |> assert_has(css("h1", text: "Example app"))
        end

        # Two people at once: each session is a Chrome of its own, with its own cookies.
        @sessions 2
        feature "a message reaches the other person", %{sessions: [alice, bob]} do
          alice |> visit(url("/chat")) |> fill_in(text_field("Message"), with: "hi") |> click(button("Send"))
          bob |> visit(url("/chat")) |> assert_has(css(".message", text: "hi"))
        end
      end

  Everything else is Wallaby's: `Wallaby.Browser` and the queries of `Wallaby.Query` are imported, `Query`
  is aliased, and `Wallaby.Feature` gives `feature/3` and `@sessions N` for
  several sessions, `@sessions [[window_size: [width: 400, height: 800]]]` for options of one's own.
  Options to `use` go to `ExUnit.Case` (`async: true` runs the module's features alongside other modules').
  """

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, unquote(opts)
      use Wallaby.Feature
      # The queries (not Query.text/2, which Browser.text/2 would clash with: write Query.text("…")).
      import Wallaby.Query,
        only: [
          css: 1,
          css: 2,
          xpath: 1,
          xpath: 2,
          button: 1,
          button: 2,
          link: 1,
          link: 2,
          text_field: 1,
          text_field: 2,
          fillable_field: 1,
          fillable_field: 2,
          checkbox: 1,
          checkbox: 2,
          radio_button: 1,
          radio_button: 2,
          select: 1,
          select: 2,
          option: 1,
          option: 2,
          file_field: 1,
          file_field: 2
        ]

      import Clawswap.Feature, only: [url: 0, url: 1, url: 2]
    end
  end

  @doc """
  The address of one of the project's servers by its name in the config (the first with a port when
  there's no name), or of clawswap's page with `:clawswap`, plus `path`: `url(:web, "/chat")`, `url("/chat")`.
  """
  def url(server \\ nil, path \\ "/")
  def url(path, "/") when is_binary(path), do: url(nil, path)
  def url(server, path), do: Clawswap.Config.url(project(), server, path)

  defp project do
    Application.get_env(:clawswap, :browser_tests_project) || raise "url/2 needs the project's config: run the tests with clawswap test"
  end
end
