# Clean up test batch directory before running tests
# Use ExUnit's on_suite_start callback to ensure this runs after config is loaded
ExUnit.after_suite(fn _results ->
  # Clean up test batch directory after all tests complete
  test_batch_dir = Application.get_env(:batcher, :batch_storage)[:base_path]

  if test_batch_dir && File.exists?(test_batch_dir) do
    File.rm_rf!(test_batch_dir)
  end
end)

# Configure ExUnit concurrency for database-heavy tests.
# Can be overridden with EXUNIT_MAX_CASES environment variable
# For systems under heavy load (100% CPU), use EXUNIT_MAX_CASES=1 for sequential execution
max_cases =
  System.get_env("EXUNIT_MAX_CASES")
  |> case do
    # Postgres + SQL sandbox can run more DB tests in parallel safely.
    nil -> min(8, System.schedulers_online())
    val -> String.to_integer(val)
  end

# Exclude integration tests by default that require external services
# Run with: mix test --include rabbitmq
ExUnit.start(max_cases: max_cases, exclude: [:rabbitmq])
Ecto.Adapters.SQL.Sandbox.mode(Batcher.Repo, :manual)
