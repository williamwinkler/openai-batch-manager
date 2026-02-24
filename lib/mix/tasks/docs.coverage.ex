defmodule Mix.Tasks.Docs.Coverage do
  use Mix.Task

  @shortdoc "Checks @moduledoc/@doc coverage and writes an artifact report"

  @moduledoc """
  Audits documentation coverage for domain and controller modules.

  By default, prints a summary and writes `tmp/quality/docs_coverage.json`.
  Use `--strict` to fail when violations are present.
  """

  @scope_globs [
    "lib/batcher/**/*.ex",
    "lib/batcher_web/controllers/**/*.ex"
  ]

  @moduledoc_false_allowlist MapSet.new([
                               "lib/batcher/application.ex"
                             ])

  @interface_module_patterns [
    ~r|^lib/batcher/batching\.ex$|,
    ~r|^lib/batcher/settings\.ex$|,
    ~r|^lib/batcher/clients/openai/api_client\.ex$|,
    ~r|^lib/batcher_web/controllers/batch_file_controller\.ex$|,
    ~r|^lib/batcher_web/controllers/request_controller\.ex$|
  ]

  @callback_module_patterns [
    ~r|^lib/batcher/batching/actions/.*\.ex$|,
    ~r|^lib/batcher/batching/changes/.*\.ex$|,
    ~r|^lib/batcher/batching/calculations/.*\.ex$|,
    ~r|^lib/batcher/batching/validations/.*\.ex$|,
    ~r|^lib/batcher_web/controllers/error_html\.ex$|,
    ~r|^lib/batcher_web/controllers/error_json\.ex$|
  ]

  @rules %{
    scope_globs: @scope_globs,
    moduledoc_false_allowlist: @moduledoc_false_allowlist,
    interface_module_patterns: @interface_module_patterns,
    callback_module_patterns: @callback_module_patterns
  }

  @artifact_path "tmp/quality/docs_coverage.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    strict? = Enum.member?(args, "--strict")
    files = scoped_files(@rules)

    violations =
      files
      |> Enum.flat_map(&audit_file(&1, @rules))
      |> Enum.sort_by(fn %{file: file, line: line} -> {file, line || 0} end)

    report = %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      strict: strict?,
      rules: %{
        scope_globs: @scope_globs,
        moduledoc_false_allowlist: MapSet.to_list(@moduledoc_false_allowlist),
        interface_module_patterns: Enum.map(@interface_module_patterns, &Regex.source/1),
        callback_module_patterns: Enum.map(@callback_module_patterns, &Regex.source/1)
      },
      summary: %{
        scanned_files: length(files),
        violations: length(violations),
        by_type: Enum.frequencies_by(violations, & &1.type)
      },
      violations: violations
    }

    write_report(report, @artifact_path)
    print_summary(report, @artifact_path)

    if strict? and violations != [] do
      Mix.raise("Documentation coverage check failed with #{length(violations)} violation(s)")
    end
  end

  @doc false
  def default_rules, do: @rules

  @doc false
  def scoped_files(rules) do
    rules.scope_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to_cwd/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def audit_file(relative_path, rules) do
    relative_path
    |> File.read!()
    |> audit_content(relative_path, rules)
  end

  @doc false
  def audit_content(content, relative_path, rules) when is_binary(content) do
    lines = String.split(content, "\n")
    type = module_type(relative_path, rules)

    moduledoc_violations = moduledoc_violations(lines, relative_path, rules)
    function_violations = function_doc_violations(lines, relative_path, type)

    moduledoc_violations ++ function_violations
  end

  @doc false
  def module_type(relative_path, rules) do
    cond do
      matches_any?(relative_path, rules.interface_module_patterns) -> :interface
      matches_any?(relative_path, rules.callback_module_patterns) -> :callback
      true -> :none
    end
  end

  defp moduledoc_violations(lines, relative_path, rules) do
    has_moduledoc? = Enum.any?(lines, &String.match?(&1, ~r/^\s*@moduledoc\b/))
    has_moduledoc_false? = Enum.any?(lines, &String.match?(&1, ~r/^\s*@moduledoc\s+false\b/))

    cond do
      not has_moduledoc? ->
        [
          violation(relative_path, "missing_moduledoc", "Missing @moduledoc declaration", 1)
        ]

      has_moduledoc_false? and not MapSet.member?(rules.moduledoc_false_allowlist, relative_path) ->
        [
          violation(
            relative_path,
            "disallowed_moduledoc_false",
            "@moduledoc false is not allowlisted for this module",
            find_line(lines, ~r/^\s*@moduledoc\s+false\b/)
          )
        ]

      true ->
        []
    end
  end

  defp function_doc_violations(_lines, _relative_path, :none), do: []

  defp function_doc_violations(lines, relative_path, type) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_no} ->
      String.match?(line, ~r/^\s*def\s+[a-zA-Z_]\w*[!?]?\s*\(/)
    end)
    |> Enum.flat_map(fn {line, line_no} ->
      fun_name = extract_fun_name(line)

      if documented?(lines, line_no) do
        []
      else
        message =
          case type do
            :interface ->
              "Missing @doc for public function #{fun_name}"

            :callback ->
              "Missing explicit @doc or @doc false for callback function #{fun_name}"
          end

        [violation(relative_path, "missing_doc", message, line_no)]
      end
    end)
  end

  defp documented?(lines, line_no) do
    start_line = previous_function_line(lines, line_no - 1) + 1
    window = Enum.slice(lines, (start_line - 1)..(line_no - 2))
    Enum.any?(window, &String.match?(&1, ~r/^\s*@doc\b/))
  end

  defp previous_function_line(_lines, 0), do: 0

  defp previous_function_line(lines, idx) do
    line = Enum.at(lines, idx - 1) || ""

    if String.match?(line, ~r/^\s*defp?\s+[a-zA-Z_]\w*[!?]?\s*\(/) do
      idx
    else
      previous_function_line(lines, idx - 1)
    end
  end

  defp extract_fun_name(line) do
    case Regex.run(~r/^\s*def\s+([a-zA-Z_]\w*[!?]?)/, line, capture: :all_but_first) do
      [name] -> name
      _ -> "unknown"
    end
  end

  defp find_line(lines, regex) do
    lines
    |> Enum.with_index(1)
    |> Enum.find_value(1, fn {line, line_no} ->
      if String.match?(line, regex), do: line_no, else: nil
    end)
  end

  defp matches_any?(path, patterns) do
    Enum.any?(patterns, &Regex.match?(&1, path))
  end

  defp violation(file, type, message, line) do
    %{
      file: file,
      type: type,
      message: message,
      line: line
    }
  end

  defp write_report(report, artifact_path) do
    artifact_path
    |> Path.dirname()
    |> File.mkdir_p!()

    artifact_path
    |> File.write!(Jason.encode_to_iodata!(report, pretty: true))
  end

  defp print_summary(report, artifact_path) do
    summary = report.summary

    Mix.shell().info("Docs coverage")
    Mix.shell().info("  Scanned files: #{summary.scanned_files}")
    Mix.shell().info("  Violations: #{summary.violations}")
    Mix.shell().info("  Artifact: #{artifact_path}")

    if summary.violations > 0 do
      Mix.shell().info("  Breakdown by type:")

      summary.by_type
      |> Enum.sort_by(fn {type, _count} -> type end)
      |> Enum.each(fn {type, count} ->
        Mix.shell().info("    - #{type}: #{count}")
      end)
    end
  end
end
