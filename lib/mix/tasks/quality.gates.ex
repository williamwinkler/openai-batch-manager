defmodule Mix.Tasks.Quality.Gates do
  @moduledoc """
  Runs OSS quality gates for CI.
  """
  use Mix.Task

  @shortdoc "Runs project quality gates"

  @audit_dir "docs/audits"
  @doc_allowlist_path "docs/audits/doc_allowlist.txt"
  @runtime_glob "lib/**/*.ex"
  @web_glob "lib/batcher_web/**/*.ex"

  @tooling_noise_patterns [
    ~r{(^|/)\.DS_Store$},
    ~r{(^|/)\.elixir_ls/},
    ~r{(^|/)\.lexical/},
    ~r{(^|/)\.idea/},
    ~r{(^|/)\.vscode/},
    ~r{(^|/)npm-debug\.log$},
    ~r{(^|/)yarn-error\.log$}
  ]

  @impl true
  @doc """
  Executes all blocking quality gates and exits non-zero on failure.
  """
  def run(_args) do
    Mix.Task.run("app.start")

    checks = [
      {"G1 unresolved runtime-critical P0/P1 findings", &gate_unresolved_runtime_findings/0},
      {"G2 no direct Ash.* in web modules", &gate_no_direct_ash_web_orchestration/0},
      {"G3 no tooling-noise tracked files", &gate_no_tooling_noise/0},
      {"G5 runtime docs coverage", &gate_runtime_docs_coverage/0}
    ]

    failures =
      Enum.flat_map(checks, fn {name, checker} ->
        case checker.() do
          :ok ->
            Mix.shell().info("PASS #{name}")
            []

          {:error, message} ->
            Mix.shell().error("FAIL #{name}")
            Mix.shell().error(message)
            [name]
        end
      end)

    if failures == [] do
      Mix.shell().info("All quality gates passed.")
    else
      Mix.raise("Quality gates failed: #{Enum.join(failures, ", ")}")
    end
  end

  defp gate_unresolved_runtime_findings do
    with {:ok, findings_path, matrix_path} <- latest_audit_artifacts(),
         {:ok, findings} <- load_findings(findings_path),
         {:ok, classification_by_path} <- load_matrix_classifications(matrix_path) do
      unresolved =
        Enum.filter(findings, fn finding ->
          finding["severity"] in ["P0", "P1"] and
            finding["status"] in ["confirmed", "needs-verification"] and
            Map.get(classification_by_path, get_in(finding, ["location", "path"])) ==
              "runtime-critical"
        end)

      if unresolved == [] do
        :ok
      else
        lines =
          Enum.map(unresolved, fn finding ->
            id = finding["id"] || "UNKNOWN"
            path = get_in(finding, ["location", "path"]) || "unknown"
            line = get_in(finding, ["location", "line"]) || 1
            "- #{id} at #{path}:#{line}"
          end)

        {:error,
         "Unresolved runtime-critical P0/P1 findings:\n" <>
           Enum.join(lines, "\n") <>
           "\nUpdate the latest audit findings status after fixes."}
      end
    else
      {:skip, reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp gate_no_direct_ash_web_orchestration do
    files = Path.wildcard(@web_glob)

    violations =
      Enum.flat_map(files, fn file ->
        content = File.read!(file)

        Regex.scan(
          ~r/\bAsh\.(read|read!|get|get!|load|load!|create|create!|update|update!|destroy|destroy!|Changeset|Query)\b/,
          content,
          return: :index
        )
        |> Enum.map(fn [{start, _len} | _] ->
          line =
            content
            |> binary_part(0, start)
            |> String.split("\n")
            |> length()

          "#{file}:#{line}"
        end)
      end)
      |> Enum.uniq()

    if violations == [] do
      :ok
    else
      {:error,
       "Direct Ash orchestration detected in web modules:\n" <> Enum.join(violations, "\n")}
    end
  end

  defp gate_no_tooling_noise do
    {output, 0} = System.cmd("git", ["ls-files"], stderr_to_stdout: true)

    tracked = output |> String.split("\n", trim: true)

    offenders =
      Enum.filter(tracked, fn path ->
        Enum.any?(@tooling_noise_patterns, &Regex.match?(&1, path))
      end)

    if offenders == [] do
      :ok
    else
      {:error, "Tooling/noise files tracked in git:\n" <> Enum.join(offenders, "\n")}
    end
  end

  defp gate_runtime_docs_coverage do
    allowlist = load_doc_allowlist()
    runtime_files = Path.wildcard(@runtime_glob)

    missing_moduledoc =
      Enum.filter(runtime_files, fn file ->
        content = File.read!(file)

        String.contains?(content, "defmodule ") and
          not Regex.match?(~r/@moduledoc\s+(false|""")/, content)
      end)
      |> Enum.map(&"mod:#{&1}")

    missing_docs =
      Enum.flat_map(runtime_files, fn file ->
        find_missing_public_docs(file)
      end)

    offenders =
      (missing_moduledoc ++ missing_docs)
      |> Enum.reject(&MapSet.member?(allowlist, &1))
      |> Enum.sort()

    if offenders == [] do
      :ok
    else
      {:error,
       "Runtime docs coverage violations (not in allowlist):\n" <>
         Enum.join(offenders, "\n") <>
         "\nAdd intentional exceptions to #{@doc_allowlist_path} as needed."}
    end
  end

  defp find_missing_public_docs(file) do
    lines = File.read!(file) |> String.split("\n")

    {_pending_doc, missing} =
      Enum.reduce(Enum.with_index(lines, 1), {false, []}, fn {line, idx}, {pending_doc, acc} ->
        cond do
          Regex.match?(~r/^\s*@doc(\s+false|\s+""")/, line) ->
            {true, acc}

          Regex.match?(~r/^\s*@(?:spec|since|deprecated)\b/, line) and pending_doc ->
            {true, acc}

          Regex.match?(~r/^\s*def\s+[a-zA-Z0-9_!?]+/, line) ->
            key = "fun:#{file}:#{extract_function_name(line, idx)}"
            {false, if(pending_doc, do: acc, else: [key | acc])}

          Regex.match?(~r/^\s*(#.*)?$/, line) ->
            {pending_doc, acc}

          true ->
            {false, acc}
        end
      end)

    Enum.uniq(missing)
  end

  defp extract_function_name(line, fallback_line) do
    case Regex.run(~r/^\s*def\s+([a-zA-Z0-9_!?]+)/, line) do
      [_, name] -> name
      _ -> "line_#{fallback_line}"
    end
  end

  defp load_doc_allowlist do
    case File.read(@doc_allowlist_path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  defp latest_audit_artifacts do
    findings =
      Path.wildcard(
        Path.join(@audit_dir, "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_findings.json")
      )
      |> Enum.sort()

    matrix =
      Path.wildcard(
        Path.join(@audit_dir, "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_file_matrix.csv")
      )
      |> Enum.sort()

    case {List.last(findings), List.last(matrix)} do
      {nil, _} ->
        {:skip, "No findings JSON found in #{@audit_dir}."}

      {_, nil} ->
        {:skip, "No file matrix CSV found in #{@audit_dir}."}

      {findings_path, matrix_path} ->
        {:ok, findings_path, matrix_path}
    end
  end

  defp load_findings(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw) do
      {:ok, Map.get(decoded, "findings", [])}
    else
      {:error, reason} -> {:error, "Failed to parse findings JSON #{path}: #{inspect(reason)}"}
    end
  end

  defp load_matrix_classifications(path) do
    with {:ok, raw} <- File.read(path) do
      rows =
        raw
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> Enum.map(&parse_csv_line/1)
        |> Enum.filter(&(length(&1) >= 2))

      by_path =
        Map.new(rows, fn [path, classification | _] ->
          {path, classification}
        end)

      {:ok, by_path}
    else
      {:error, reason} -> {:error, "Failed to read matrix CSV #{path}: #{inspect(reason)}"}
    end
  end

  defp parse_csv_line(line) do
    parse_csv_line(line, [], "", false)
  end

  defp parse_csv_line(<<>>, fields, current, _in_quotes) do
    Enum.reverse([current | fields])
  end

  defp parse_csv_line(<<"\"", rest::binary>>, fields, current, false) do
    parse_csv_line(rest, fields, current, true)
  end

  defp parse_csv_line(<<"\"", rest::binary>>, fields, current, true) do
    case rest do
      <<"\"", tail::binary>> -> parse_csv_line(tail, fields, current <> "\"", true)
      _ -> parse_csv_line(rest, fields, current, false)
    end
  end

  defp parse_csv_line(<<",", rest::binary>>, fields, current, false) do
    parse_csv_line(rest, [current | fields], "", false)
  end

  defp parse_csv_line(<<char::utf8, rest::binary>>, fields, current, in_quotes) do
    parse_csv_line(rest, fields, current <> <<char::utf8>>, in_quotes)
  end
end
