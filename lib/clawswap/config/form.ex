defmodule Clawswap.Config.Form do
  @moduledoc """
  The settings page's form for the project's config file, and writing it back in the file's own format.

  The form holds text: `values` maps a field's id to what's in its input, `code` marks the fields shown
  as Elixir (a function, a variable, a Regex with options: anything a plain input can't hold) and `rows`
  lists each section's rows. A `when` line written `/.../` is a Regex, as in a clawswap.yml.

  A clawswap.exs is changed in place rather than written afresh: the file is parsed with its comments,
  only the keys and rows that changed are replaced, and the formatter prints it again. Comments, code and
  keys the form doesn't show stay as they were. A clawswap.yml is written whole, so its comments go.
  """

  alias Clawswap.Config
  alias Clawswap.Config.YamlWriter

  # {key, label, kind, hint}. Kinds: :string, :integer, :multiplexer (zellij or tmux), :command (a string, or Elixir for a list),
  # :lines (one per line), :when (paths and /regexes/, one per line), :regex, :code (always Elixir).
  @general [
    {:name, "Name", :string, "the repo folder's name"},
    {:session, "Session", :string, "the name"},
    {:base, "Base branch", :string, "origin's default branch"},
    {:port, "Port", :integer, "8790"},
    {:multiplexer, "Multiplexer", :multiplexer, "detected"},
    {:layout, "zellij layout file", :string, "generated"},
    {:origins, "Origins allowed to call the API", :lines, "one per line; the servers' localhost ports always are"},
    {:restart_when, "Also restart the watcher when these change", :when, "paths or /regexes/, one per line"},
    {:short_name, "Short name for a branch", :code, "drops claude/"},
    {:walkthroughs, "Walkthroughs folder", :string, "walkthroughs, next to the config"}
  ]

  # {key, label, :named (a keyword list of name: fields) or :list, fields}
  @sections [
    {:servers, "Servers", "Stopped and started again by a switch, each in a pane of its name.", :named,
     [
       {:command, "Command", :command, "npm run dev"},
       {:cwd, "Folder", :string, "."},
       {:port, "Port", :integer, "freed before checkout"},
       {:match, "Match", :regex, "/regex/ to find a renamed pane"}
     ]},
    {:panes, "Other panes", "Left running across switches.", :named, [{:command, "Command", :command, ""}, {:cwd, "Folder", :string, "."}]},
    {:prepare, "Prepare", "What up runs before it starts a new session.", :list,
     [
       {:label, "Label", :string, ""},
       {:run, "Run", :command, ""},
       {:cwd, "Folder", :string, "."},
       {:wait_for_port, "Wait for port", :integer, ""}
     ]},
    {:steps, "Steps", "What a switch runs when matching files changed, in this order.", :list,
     [
       {:label, "Label", :string, ""},
       {:when, "When", :when, "paths or /regexes/, one per line"},
       {:run, "Run", :command, ""},
       {:cwd, "Folder", :string, "."}
     ]},
    {:notes, "Notes", "Said after a switch that changed matching files.", :list,
     [{:when, "When", :when, "paths or /regexes/, one per line"}, {:message, "Message", :string, ""}]}
  ]

  @managed Enum.map(@general, &elem(&1, 0)) ++ Enum.map(@sections, &elem(&1, 0))

  @parse_opts [literal_encoder: &__MODULE__.encode_literal/2, token_metadata: true, columns: true]

  @doc false
  def encode_literal(literal, meta), do: {:ok, {:__block__, meta, [literal]}}

  @doc "The fields and sections, for the page to lay out."
  def schema do
    field = fn {key, label, kind, hint} ->
      options = if kind == :multiplexer, do: ["zellij", "tmux"], else: []
      %{key: to_string(key), label: label, hint: hint, wide: kind in [:lines, :when, :code], long: kind == :command, options: options}
    end

    %{
      general: Enum.map(@general, field),
      sections:
        for {key, label, about, shape, fields} <- @sections do
          %{key: to_string(key), label: label, about: about, named: shape == :named, fields: Enum.map(fields, field)}
        end
    }
  end

  def path(project), do: Path.expand(project.file, project.root)

  def yaml?(path), do: Path.extname(path) in [".yml", ".yaml"]

  defp mode(path), do: if(yaml?(path), do: :yaml, else: :exs)

  @doc """
  The form for the project's config file: `{:ok, %{file, format, values, code, rows, next}}`, or
  `{:error, message}` when it can't be read.
  """
  def load(project) do
    path = path(project)

    mode = mode(path)

    with {:ok, ast, _comments} <- parse(path),
         {:ok, top} <- top_pairs(ast) do
      acc = %{values: %{}, code: %{}, rows: %{}, next: 1, mode: mode}

      acc =
        Enum.reduce(@general, acc, fn {key, _, kind, _}, acc ->
          put_field(acc, to_string(key), top[key], kind)
        end)

      acc = Enum.reduce(@sections, acc, fn section, acc -> load_section(acc, section, top[elem(section, 0)]) end)

      {:ok, acc |> Map.delete(:mode) |> Map.merge(%{file: project.file, format: to_string(mode)})}
    end
  end

  defp load_section(acc, {key, _, _, shape, fields}, ast) do
    key = to_string(key)

    case section_rows(ast, shape) do
      {:ok, rows} ->
        acc = put_in(acc.rows[key], [])

        Enum.reduce(rows, acc, fn {orig, row}, acc ->
          id = "r#{acc.next}"
          prefix = "#{key}.#{id}."
          acc = %{acc | next: acc.next + 1}
          acc = update_in(acc.rows[key], &(&1 ++ [%{id: id, orig: orig}]))
          acc = if shape == :named, do: put_in(acc.values[prefix <> "_name"], orig), else: acc
          Enum.reduce(fields, acc, fn {f, _, kind, _}, acc -> put_field(acc, prefix <> to_string(f), row[f], kind) end)
        end)

      :error ->
        acc |> put_in([:rows, key], []) |> put_field(key <> "._code", ast, :code)
    end
  end

  # A section's rows as {orig, %{field => ast}}: orig is the name, or the index for a list. :error when
  # it isn't written out as a list the form can show (a variable, say).
  defp section_rows(nil, _), do: {:ok, []}

  defp section_rows(ast, :named) do
    with {:ok, pairs} <- pairs(ast) do
      Enum.reduce_while(pairs, {:ok, []}, fn {name, row}, {:ok, acc} ->
        case pairs(row) do
          {:ok, fields} -> {:cont, {:ok, acc ++ [{to_string(name), Map.new(fields)}]}}
          :error -> {:halt, :error}
        end
      end)
    end
  end

  defp section_rows(ast, :list) do
    with {:ok, items} <- list(ast) do
      items
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {row, i}, {:ok, acc} ->
        case pairs(row) do
          {:ok, fields} -> {:cont, {:ok, acc ++ [{to_string(i), Map.new(fields)}]}}
          :error -> {:halt, :error}
        end
      end)
    end
  end

  defp put_field(acc, id, nil, :code), do: %{acc | values: Map.put(acc.values, id, ""), code: Map.put(acc.code, id, true)}

  defp put_field(acc, id, ast, kind) do
    case {kind, eval(ast)} do
      # A YAML file's Elixir is a string already.
      {:code, {:ok, text}} when acc.mode == :yaml and is_binary(text) ->
        %{acc | values: Map.put(acc.values, id, text), code: Map.put(acc.code, id, true)}

      {:code, _} ->
        %{acc | values: Map.put(acc.values, id, source(ast)), code: Map.put(acc.code, id, true)}

      {_, {:ok, value}} ->
        case text(value, kind) do
          {:ok, text} -> put_in(acc.values[id], text)
          :error -> %{acc | values: Map.put(acc.values, id, source(ast)), code: Map.put(acc.code, id, true)}
        end

      _ ->
        %{acc | values: Map.put(acc.values, id, source(ast)), code: Map.put(acc.code, id, true)}
    end
  end

  defp text(nil, _), do: {:ok, ""}
  defp text(s, kind) when is_binary(s) and kind in [:string, :command], do: {:ok, s}
  defp text(s, kind) when is_binary(s) and kind in [:lines, :when], do: if(String.contains?(s, "\n"), do: :error, else: {:ok, s})
  defp text(s, :regex) when is_binary(s), do: if(match?({:regex, _}, regex(s)), do: {:ok, s}, else: :error)
  defp text(a, kind) when is_atom(a) and not is_boolean(a) and kind in [:string, :multiplexer], do: {:ok, Atom.to_string(a)}
  defp text(s, :multiplexer) when is_binary(s), do: {:ok, s}
  defp text(n, :integer) when is_integer(n), do: {:ok, Integer.to_string(n)}

  defp text(%Regex{} = r, kind) when kind in [:regex, :when] do
    if Regex.opts(r) == [], do: {:ok, "/#{r.source}/"}, else: :error
  end

  defp text(list, kind) when is_list(list) and kind in [:lines, :when] do
    texts = Enum.map(list, &text(&1, kind))
    if Enum.all?(texts, &match?({:ok, t} when t != "", &1)) and list != [], do: {:ok, Enum.map_join(texts, "\n", &elem(&1, 1))}, else: :error
  end

  defp text(_, _), do: :error

  @doc """
  Writes the form back to the project's config file, in its format, after checking that clawswap can
  load the result. `{:ok, :saved}`, `{:ok, :unchanged}` or `{:error, message}`.
  """
  def save(project, %{values: values, code: code, rows: rows}) do
    path = path(project)
    mode = mode(path)

    with {:ok, ast, comments} <- parse(path),
         {:ok, top} <- top_pairs(ast),
         {:ok, list} <- body(ast),
         {:ok, changes} <- form_changes(mode, values, code, rows, Map.new(top)) do
      new_list = rewrap(list, merge_pairs(unwrap(list), changes, @managed))

      if new_list == list do
        {:ok, :unchanged}
      else
        new_ast = put_body(ast, new_list)

        with {:ok, content} <- render(new_ast, comments, path, project),
             :ok <- check(content, path, project) do
          File.write!(path, content)
          {:ok, :saved}
        end
      end
    end
  end

  # For each managed key, its new AST, or :drop.
  defp form_changes(mode, values, code, rows, old) do
    general =
      for {key, label, kind, _} <- @general do
        id = to_string(key)
        {key, value_ast(mode, old[key], values[id] || "", Map.has_key?(code, id), kind, label)}
      end

    sections = for {key, _, _, _, _} = s <- @sections, do: {key, section_ast(mode, s, old[key], values, code, rows)}

    case Enum.find(general ++ sections, &match?({_, {:error, _}}, &1)) do
      {_, error} -> error
      nil -> {:ok, for({key, {:ok, ast}} <- general ++ sections, do: {key, ast})}
    end
  end

  # A field's new AST from its text: the old AST when the text still says the same thing.
  defp value_ast(:yaml, old, text, true, :code, _label) do
    text = String.trim(text)

    cond do
      text == "" -> {:ok, :drop}
      old && eval(old) == {:ok, text} -> {:ok, old}
      true -> {:ok, text}
    end
  end

  defp value_ast(_mode, old, text, true, _kind, label) do
    cond do
      String.trim(text) == "" ->
        {:ok, :drop}

      old && source(old) == text ->
        {:ok, old}

      true ->
        case Code.string_to_quoted(text) do
          {:ok, ast} -> {:ok, ast}
          {:error, {_, message, token}} -> {:error, "#{label}: #{message_text(message)}#{token}"}
        end
    end
  end

  defp value_ast(_mode, old, text, false, kind, label) do
    case parse_text(String.trim(text), kind) do
      :drop -> {:ok, :drop}
      {:error, message} -> {:error, "#{label}: #{message}"}
      {:ok, term} -> if old && same?(old, term), do: {:ok, old}, else: {:ok, to_ast(term)}
    end
  end

  defp message_text({a, b}), do: "#{a}#{b}"
  defp message_text(message), do: to_string(message)

  defp parse_text("", _), do: :drop

  defp parse_text(text, :integer) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "#{inspect(text)} isn't a number"}
    end
  end

  defp parse_text(text, :multiplexer) do
    if text in ["zellij", "tmux"], do: {:ok, String.to_atom(text)}, else: {:error, "zellij or tmux"}
  end

  defp parse_text(text, :regex) do
    case regex(text) do
      {:regex, _} = r -> {:ok, r}
      _ -> {:error, "write it as /regex/"}
    end
  end

  defp parse_text(text, kind) when kind in [:lines, :when] do
    lines = text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    lines = if kind == :when, do: Enum.map(lines, &regex/1), else: lines

    with {:regex, source} <- Enum.find(lines, :ok, &match?({:regex, _}, &1)),
         {:error, {message, _}} <- Regex.compile(source) do
      {:error, "/#{source}/: #{message}"}
    else
      _ -> {:ok, if(match?([_], lines), do: hd(lines), else: lines)}
    end
  end

  defp parse_text(text, _), do: {:ok, text}

  defp regex("/" <> rest = text) when byte_size(rest) > 1 do
    if String.ends_with?(rest, "/"), do: {:regex, String.slice(rest, 0..-2//1)}, else: text
  end

  defp regex(text), do: text

  # Whether an old AST already says what the form's text does, so it can stay as written.
  defp same?(old, term) do
    case eval(old) do
      {:ok, value} -> List.wrap(canonical(value)) == List.wrap(canonical(term))
      :error -> false
    end
  end

  defp canonical(%Regex{} = r), do: if(Regex.opts(r) == [], do: {:regex, r.source}, else: r)
  defp canonical(s) when is_binary(s), do: regex(s)
  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(a) when is_atom(a) and not is_nil(a) and not is_boolean(a), do: Atom.to_string(a)
  defp canonical(v), do: v

  defp to_ast({:regex, source}) do
    {delimiter, source} =
      cond do
        not String.contains?(source, "/") -> {"/", source}
        not String.contains?(source, "|") -> {"|", source}
        true -> {"/", String.replace(source, "/", "\\/")}
      end

    {:sigil_r, [delimiter: delimiter], [{:<<>>, [], [source]}, []]}
  end

  defp to_ast(list) when is_list(list), do: wrap(Enum.map(list, &to_ast/1))
  defp to_ast(v), do: v

  defp section_ast(mode, {key, label, _, shape, fields}, old, values, code, rows) do
    skey = to_string(key)

    if Map.has_key?(code, skey <> "._code") do
      value_ast(:exs, old, values[skey <> "._code"] || "", true, :section, label)
    else
      old_rows =
        case section_rows(old, shape) do
          {:ok, rs} -> Map.new(rs)
          :error -> %{}
        end

      old_row_asts = old_row_asts(old, shape)

      (rows[skey] || [])
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {row, n}, {:ok, acc} ->
        prefix = "#{skey}.#{row.id}."
        orig = row[:orig]
        old_fields = (orig && old_rows[orig]) || %{}

        changes =
          for {f, flabel, kind, _} <- fields do
            id = prefix <> to_string(f)
            {f, value_ast(mode, old_fields[f], values[id] || "", Map.has_key?(code, id), kind, "#{label} #{n}, #{flabel}")}
          end

        with nil <- Enum.find_value(changes, fn {_, r} -> match?({:error, _}, r) && r end),
             {:ok, name} <- row_name(shape, values[prefix <> "_name"], label, n, acc) do
          changes = for {f, {:ok, ast}} <- changes, do: {f, ast}
          old_row = orig && old_row_asts[orig]
          row_ast = if old_row, do: rewrap(old_row, merge_pairs(unwrap(old_row), changes, Enum.map(fields, &elem(&1, 0)))), else: new_pairs(changes)
          {:cont, {:ok, acc ++ [{name, orig, row_ast}]}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, []} -> {:ok, if(old && match?({:ok, []}, list(old)), do: old, else: :drop)}
        {:ok, built} -> {:ok, build_section(old, shape, built, old_keys(old, shape))}
        error -> error
      end
    end
  end

  defp row_name(:list, _, _, _, _), do: {:ok, nil}

  defp row_name(:named, name, label, n, acc) do
    name = String.trim(name || "")

    cond do
      name == "" -> {:error, "#{label} #{n} needs a name"}
      not Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*$/, name) -> {:error, "#{label} #{n}: name it with lowercase letters, digits and _"}
      Enum.any?(acc, &(elem(&1, 0) == name)) -> {:error, "#{label}: two are called #{name}"}
      true -> {:ok, name}
    end
  end

  defp old_row_asts(nil, _), do: %{}

  defp old_row_asts(old, :named) do
    case list(old) do
      {:ok, items} -> for item <- items, {name, value} = pair(item), into: %{}, do: {to_string(name), value}
      :error -> %{}
    end
  end

  defp old_row_asts(old, :list) do
    case list(old) do
      {:ok, items} -> items |> Enum.with_index() |> Map.new(fn {item, i} -> {to_string(i), item} end)
      :error -> %{}
    end
  end

  # A named section's rows keep their key's AST (and so its place for comments) while the name stays.
  defp old_keys(old, :named) do
    case old && list(old) do
      {:ok, items} -> for {key, _} <- items, {name, _} = pair({key, nil}), into: %{}, do: {to_string(name), key}
      _ -> %{}
    end
  end

  defp old_keys(_, :list), do: %{}

  defp build_section(old, :named, built, keys) do
    items = for {name, orig, row} <- built, do: {(orig == name && keys[name]) || key_ast(String.to_atom(name)), row}
    if old && match?({:ok, _}, list(old)), do: rewrap(old, items), else: wrap(items)
  end

  defp build_section(old, :list, built, _keys) do
    items = for {_, _, row} <- built, do: row
    if old && match?({:ok, _}, list(old)), do: rewrap(old, items), else: wrap(items)
  end

  # Merges new values into a keyword list's pairs: keys the form manages are replaced (or dropped), the
  # rest kept as written, and new keys go at the end.
  defp merge_pairs(items, changes, managed) do
    changes = Map.new(changes)

    kept =
      Enum.flat_map(items, fn item ->
        {key, _} = pair(item)

        cond do
          key not in managed -> [item]
          changes[key] in [nil, :drop] -> []
          true -> [set_value(item, changes[key])]
        end
      end)

    present = for item <- items, do: elem(pair(item), 0)
    added = for key <- managed, key not in present, changes[key] not in [nil, :drop], do: {key_ast(key), changes[key]}
    kept ++ added
  end

  defp new_pairs(changes), do: wrap(for {key, ast} <- changes, ast != :drop, do: {key_ast(key), ast})

  # A new list as the parser gives one, so the formatter prints it as a list wherever it goes.
  defp wrap(list), do: {:__block__, [], [list]}

  defp set_value({key, _}, value), do: {key, value}

  defp key_ast(key), do: {:__block__, [format: :keyword], [key]}

  # Parsing. A clawswap.exs is parsed with its comments; a clawswap.yml is read and escaped, so both go
  # through the same walk.
  defp parse(path) do
    if yaml?(path) do
      with {:ok, config} <- read_yaml(path), do: {:ok, Macro.escape(config), []}
    else
      with {:ok, source} <- File.read(path),
           {:ok, ast, comments} <- quoted(source) do
        {:ok, ast, comments}
      else
        {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
        error -> error
      end
    end
  end

  # As Config.Yaml reads it, but leaving strings as written: its regexes and Elixir go back as strings.
  defp read_yaml(path) do
    case YamlElixir.read_from_file(path, maps_as_keywords: true) do
      {:ok, doc} -> {:ok, atom_keys(doc || [])}
      {:error, %{message: message}} -> {:error, "#{path}: #{message}"}
      {:error, error} -> {:error, "#{path}: #{inspect(error)}"}
    end
  end

  defp atom_keys([{_, _} | _] = pairs), do: for({k, v} <- Enum.reverse(pairs), do: {String.to_atom(to_string(k)), atom_keys(v)})
  defp atom_keys(list) when is_list(list), do: Enum.map(list, &atom_keys/1)
  defp atom_keys(value), do: value

  defp quoted(source) do
    case Code.string_to_quoted_with_comments(source, @parse_opts) do
      {:ok, ast, comments} -> {:ok, ast, comments}
      {:error, {meta, message, token}} -> {:error, "line #{meta[:line]}: #{message_text(message)}#{token}"}
    end
  end

  defp top_pairs(ast) do
    with {:ok, list} <- body(ast), {:ok, pairs} <- pairs(list) do
      {:ok, pairs}
    else
      _ -> {:error, "The config doesn't end in a keyword list the form can show; edit the file itself"}
    end
  end

  # The config is the file's last expression.
  defp body({:__block__, _, [l]} = ast) when is_list(l), do: {:ok, ast}
  defp body(l) when is_list(l), do: {:ok, l}
  defp body({:__block__, _, [_, _ | _] = exprs}), do: body(List.last(exprs))
  defp body(_), do: :error

  defp put_body({:__block__, _, [l]}, new) when is_list(l), do: new
  defp put_body(l, new) when is_list(l), do: new
  defp put_body({:__block__, meta, exprs}, new), do: {:__block__, meta, List.replace_at(exprs, -1, put_body(List.last(exprs), new))}

  defp list({:__block__, _, [l]}) when is_list(l), do: {:ok, l}
  defp list(l) when is_list(l), do: {:ok, l}
  defp list(_), do: :error

  defp unwrap(ast), do: elem(list(ast), 1)

  defp rewrap({:__block__, meta, [l]}, items) when is_list(l), do: {:__block__, meta, [items]}
  defp rewrap(l, items) when is_list(l), do: items

  defp pairs(ast) do
    with {:ok, items} <- list(ast) do
      pairs = Enum.map(items, &pair/1)
      if nil in pairs, do: :error, else: {:ok, pairs}
    end
  end

  defp pair({{:__block__, _, [key]}, value}) when is_atom(key), do: {key, value}
  defp pair({key, value}) when is_atom(key), do: {key, value}
  defp pair(_), do: nil

  defp eval(ast) do
    {value, _} = Code.eval_quoted(ast)
    {:ok, value}
  rescue
    _ -> :error
  end

  defp source(ast), do: ast |> Code.quoted_to_algebra() |> Inspect.Algebra.format(98) |> IO.iodata_to_binary()

  defp render(ast, comments, path, project) do
    if yaml?(path) do
      with {:ok, config} <- eval_config(fn -> Code.eval_quoted(ast) end) do
        YamlWriter.encode(config)
      end
    else
      width = line_length(path, project.root)
      {:ok, ast |> Code.quoted_to_algebra(comments: comments) |> Inspect.Algebra.format(width) |> IO.iodata_to_binary() |> Kernel.<>("\n")}
    end
  end

  # The repo's .formatter.exs line_length, else as wide as the file's longest line (at least mix
  # format's 98), so lines nobody changed aren't wrapped anew.
  defp line_length(path, root) do
    formatter = Path.join(root, ".formatter.exs")

    from_formatter =
      try do
        if File.exists?(formatter), do: formatter |> Code.eval_file() |> elem(0) |> Keyword.get(:line_length)
      rescue
        _ -> nil
      end

    from_formatter ||
      path |> File.read!() |> String.split("\n") |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end) |> max(98)
  end

  # Loads the new content as clawswap would, so a save can't leave a config that doesn't start.
  defp check(content, path, project) do
    loaded =
      if yaml?(path) do
        tmp = Path.join(System.tmp_dir!(), "clawswap-#{System.unique_integer([:positive])}#{Path.extname(path)}")
        File.write!(tmp, content)

        try do
          Config.read(tmp)
        after
          File.rm(tmp)
        end
      else
        eval_config(fn -> Code.eval_string(content, [], file: path) end)
      end

    with {:ok, config} <- loaded do
      Config.normalise(config || [], root: project.root, file: project.file)
      :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp eval_config(fun) do
    {config, _} = fun.()
    {:ok, config}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
