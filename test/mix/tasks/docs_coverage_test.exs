defmodule Mix.Tasks.Docs.CoverageTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Docs.Coverage

  test "flags missing moduledoc in scoped file" do
    content = """
    defmodule Batcher.Example do
      def run(), do: :ok
    end
    """

    violations =
      Coverage.audit_content(content, "lib/batcher/example.ex", Coverage.default_rules())

    assert Enum.any?(violations, &(&1.type == "missing_moduledoc"))
  end

  test "flags missing @doc for interface module public function" do
    content = """
    defmodule Batcher.Settings do
      @moduledoc \"\"\"
      Settings API.
      \"\"\"

      def get_rate_limit_settings!(), do: :ok
    end
    """

    violations =
      Coverage.audit_content(content, "lib/batcher/settings.ex", Coverage.default_rules())

    assert Enum.any?(violations, &(&1.type == "missing_doc"))
  end

  test "allows @doc false for callback module public function" do
    content = """
    defmodule Batcher.Batching.Actions.CheckBatchStatus do
      @moduledoc \"\"\"
      Callback action.
      \"\"\"

      @doc false
      def run(input, _opts, _context), do: input
    end
    """

    violations =
      Coverage.audit_content(
        content,
        "lib/batcher/batching/actions/check_batch_status.ex",
        Coverage.default_rules()
      )

    refute Enum.any?(violations, &(&1.type == "missing_doc"))
  end

  test "allows moduledoc false for allowlisted module" do
    content = """
    defmodule Batcher.Application do
      @moduledoc false
      def start(_type, _args), do: {:ok, self()}
    end
    """

    violations =
      Coverage.audit_content(content, "lib/batcher/application.ex", Coverage.default_rules())

    refute Enum.any?(violations, &(&1.type == "disallowed_moduledoc_false"))
  end

  test "ignores function docs for non-interface and non-callback modules" do
    content = """
    defmodule Batcher.Batching.Request do
      @moduledoc \"\"\"
      Request resource.
      \"\"\"

      def public_helper(), do: :ok
    end
    """

    violations =
      Coverage.audit_content(content, "lib/batcher/batching/request.ex", Coverage.default_rules())

    refute Enum.any?(violations, &(&1.type == "missing_doc"))
  end
end
