# Clean up test batch directory before running tests
# Use ExUnit's on_suite_start callback to ensure this runs after config is loaded
ExUnit.after_suite(fn _results ->
  # Clean up test batch directory after all tests complete
  test_batch_dir = Application.get_env(:batcher, :batch_storage)[:base_path]

  if test_batch_dir && File.exists?(test_batch_dir) do
    File.rm_rf!(test_batch_dir)
  end
end)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Batcher.Repo, :manual)
