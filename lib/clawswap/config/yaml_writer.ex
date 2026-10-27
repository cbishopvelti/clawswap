defmodule Clawswap.Config.YamlWriter do
  @moduledoc """
  Writes a config keyword list as a clawswap.yml, for the settings page (yaml_elixir only reads). Keyword
  lists are mappings, lists of plain values are written inline, a Regex is `'/.../'` and strings are
  quoted when YAML would read them as something else.
  """

  def encode(config) do
    {:ok, config |> mapping(0) |> Enum.map_join(&(&1 <> "\n"))}
  catch
    {:unwritable, message} -> {:error, message}
  end

  defp mapping(pairs, indent) do
    Enum.flat_map(pairs, fn {key, value} -> entry(pad(indent) <> to_string(key) <> ":", value, indent) end)
  end

  defp entry(head, value, indent) do
    cond do
      keyword?(value) -> [head | mapping(value, indent + 2)]
      is_list(value) and Enum.any?(value, &is_list/1) -> [head | sequence(value, indent + 2)]
      true -> [head <> " " <> scalar(value)]
    end
  end

  defp sequence(items, indent) do
    Enum.flat_map(items, fn item ->
      if keyword?(item) do
        [first | rest] = mapping(item, indent + 2)
        [pad(indent) <> "- " <> String.trim_leading(first) | rest]
      else
        [pad(indent) <> "- " <> scalar(item)]
      end
    end)
  end

  defp keyword?([_ | _] = list), do: Keyword.keyword?(list)
  defp keyword?(_), do: false

  defp scalar(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &scalar/1) <> "]"
  defp scalar(nil), do: "null"
  defp scalar(b) when is_boolean(b), do: to_string(b)
  defp scalar(n) when is_number(n), do: to_string(n)
  defp scalar(%Regex{} = r), do: quote_string("/#{r.source}/")
  defp scalar(a) when is_atom(a), do: string(Atom.to_string(a))
  defp scalar(s) when is_binary(s), do: string(s)
  defp scalar(f) when is_function(f), do: throw({:unwritable, "A function can't go in YAML; write it as Elixir in a string"})
  defp scalar(other), do: throw({:unwritable, "#{inspect(other)} can't go in YAML"})

  # Plain when it reads back as the same string: no YAML indicators, not a number, bool or null. A
  # /regex/ is quoted, as the README writes them.
  defp string(s) do
    plain =
      Regex.match?(~r/^[A-Za-z0-9_.\/][A-Za-z0-9_.\/ +=-]*$/, s) and not String.ends_with?(s, " ") and
        not Regex.match?(
          ~r/^([-+]?[0-9][0-9_.]*|[-+]?\.?(inf|Inf|INF|nan|NaN|NAN)|true|false|True|False|TRUE|FALSE|yes|no|Yes|No|YES|NO|on|off|On|Off|ON|OFF|y|n|Y|N|null|Null|NULL|~)$/,
          s
        )

    if plain and not Regex.match?(~r{^/.+/$}, s), do: s, else: quote_string(s)
  end

  # Single quotes keep backslashes as written (a Regex's, say); a newline needs double quotes.
  defp quote_string(s) do
    if String.contains?(s, ["\n", "\t", "\r"]), do: JSON.encode!(s), else: "'" <> String.replace(s, "'", "''") <> "'"
  end

  defp pad(n), do: String.duplicate(" ", n)
end
