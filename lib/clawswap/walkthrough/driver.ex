defmodule Clawswap.Walkthrough.Driver do
  @moduledoc """
  Wallaby's Chrome driver with a looser version check. Wallaby wants Chrome and chromedriver to match to
  the build number, so every Chrome update that lands before chromedriver's would stop walkthroughs;
  chromedriver itself only needs the same major version. When the walkthrough drives a Chrome that's
  already open (`Clawswap.Walkthrough.Browser`'s dev Chrome), chromedriver checks that one itself.
  """

  alias Wallaby.DependencyError

  defdelegate child_spec(opts), to: Wallaby.Chrome
  defdelegate start_session(opts), to: Wallaby.Chrome

  def validate do
    with {:ok, [driver_major | _] = driver} <- Wallaby.Chrome.get_chromedriver_version() do
      case Wallaby.Chrome.get_chrome_version() do
        {:ok, [^driver_major | _]} ->
          :ok

        {:ok, chrome} ->
          {:error,
           DependencyError.exception(
             "Chrome #{Enum.join(chrome, ".")} and chromedriver #{Enum.join(driver, ".")} differ: install the chromedriver for Chrome #{hd(chrome)} " <>
               "(https://googlechromelabs.github.io/chrome-for-testing/)"
           )}

        # No Chrome of its own to start, which is fine when it drives one that's already open.
        {:error, _} = error ->
          if Clawswap.Walkthrough.Browser.dev_chrome(), do: :ok, else: error
      end
    end
  end
end
