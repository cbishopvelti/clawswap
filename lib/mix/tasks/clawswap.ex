defmodule Mix.Tasks.Clawswap do
  @shortdoc "Runs a clawswap command (bin/clawswap runs this from the repo you are in)"
  @moduledoc """
      mix clawswap <command>

  See `Clawswap.CLI` and README.md. CLAWSWAP_REPO names the repo to act on (bin/clawswap sets it to the
  directory it was run from).
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    Clawswap.CLI.main(args)
  end
end
