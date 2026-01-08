# Clean up test batch directory before running tests
# Use ExUnit's on_suite_start callback to ensure this runs after config is loaded
ExUnit.after_suite(fn _results ->
  # Clean up test batch directory after all tests complete
  test_batch_dir = Application.get_env(:batcher, :batch_storage)[:base_path]

  if test_batch_dir && File.exists?(test_batch_dir) do
    File.rm_rf!(test_batch_dir)
  end
end)

# Configure ExUnit to run concurrent tests with SQLite WAL mode
# With WAL mode, SQLite allows concurrent readers and serializes writers
# Can be overridden with EXUNIT_MAX_CASES environment variable
# For systems under heavy load (100% CPU), use EXUNIT_MAX_CASES=1 for sequential execution
# Conservative limit: SQLite serializes writes, so too many concurrent writers cause "Database busy"
max_cases =
  System.get_env("EXUNIT_MAX_CASES")
  |> case do
    # Conservative limit: 4 concurrent test processes to avoid write contention
    # WAL mode allows concurrent reads, but writes are still serialized
    nil -> min(4, System.schedulers_online())
    val -> String.to_integer(val)
  end

ExUnit.start(max_cases: max_cases)
Ecto.Adapters.SQL.Sandbox.mode(Batcher.Repo, :manual)
