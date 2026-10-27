defmodule Clawswap.Config.Yaml do
  @moduledoc """
  Reads a clawswap.yml into the keyword list a clawswap.exs returns. Mapping keys become atoms, in the
  order written (the servers' order matters), and a `when`, `restart_when` or `match` string written as
  `/.../` is a Regex. Where a function goes (`short_name`, `when`, `restart_when`), a string starting with
  `fn ` or `&` is Elixir, evaluated when the config loads; `short_name` is always Elixir.
  """

  @regex_keys [:when, :restart_when, :match]
  @code_keys [:short_name, :when, :restart_when]

  def read(path) do
    case YamlElixir.read_from_file(path, maps_as_keywords: true) do
      {:ok, doc} -> {:ok, convert(doc || [], nil)}
      {:error, %{message: message}} -> {:error, "#{path}: #{message}"}
      {:error, error} -> {:error, "#{path}: #{inspect(error)}"}
    end
  end

  # A mapping comes back as {key, value} pairs in reverse order; a sequence never holds pairs.
  defp convert([{_, _} | _] = pairs, _key) do
    for {k, v} <- Enum.reverse(pairs) do
      k = String.to_atom(to_string(k))
      {k, convert(v, k)}
    end
  end

  defp convert(list, key) when is_list(list), do: Enum.map(list, &convert(&1, key))
  defp convert(text, :short_name) when is_binary(text), do: code(text)
  defp convert("fn " <> _ = text, key) when key in @code_keys, do: code(text)
  defp convert("&" <> _ = text, key) when key in @code_keys, do: code(text)
  defp convert("/" <> _ = text, key) when key in @regex_keys and byte_size(text) > 2, do: regex(text)
  defp convert(value, _key), do: value

  defp code(text) do
    case Code.eval_string(text) do
      {fun, _} when is_function(fun, 1) -> fun
      _ -> raise ArgumentError, "#{text} isn't a function of one argument"
    end
  end

  defp regex(text) do
    if String.ends_with?(text, "/"), do: Regex.compile!(String.slice(text, 1..-2//1)), else: text
  end
end
