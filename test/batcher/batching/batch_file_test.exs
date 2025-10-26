defmodule Batcher.Batching.BatchFileTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching.BatchFile

  setup do
    # Ensure directory exists (cleaned before test suite in test_helper.exs)
    BatchFile.ensure_directory_exists()
    :ok
  end

  describe "file_path/1" do
    test "computes correct file path for batch ID" do
      batch_id = 123
      path = BatchFile.file_path(batch_id)

      assert String.ends_with?(path, "batch_123.jsonl")
      assert String.contains?(path, "batches")
    end
  end

  describe "base_path/0" do
    test "returns configured base path" do
      path = BatchFile.base_path()
      assert is_binary(path)
      # In test environment, it should be the tmp directory
      assert String.contains?(path, "tmp/test_batches")
    end
  end

  describe "check_disk_space/0" do
    test "returns ok with available bytes when sufficient space" do
      # This test assumes the system has at least 10MB free
      assert {:ok, available_bytes} = BatchFile.check_disk_space()
      assert is_integer(available_bytes)
      assert available_bytes >= 10 * 1024 * 1024
    end
  end

  describe "ensure_directory_exists/0" do
    test "creates directory if it doesn't exist" do
      base = BatchFile.base_path()

      assert :ok = BatchFile.ensure_directory_exists()
      assert File.dir?(base)
    end

    test "succeeds if directory already exists" do
      base = BatchFile.base_path()
      File.mkdir_p!(base)

      assert :ok = BatchFile.ensure_directory_exists()
      assert File.dir?(base)
    end
  end

  describe "create_file/1" do
    test "creates empty JSONL file for batch ID" do
      batch_id = "test_batch_#{:rand.uniform(100_000)}"

      assert {:ok, path} = BatchFile.create_file(batch_id)
      assert File.exists?(path)
      assert File.read!(path) == ""
      assert String.ends_with?(path, "batch_#{batch_id}.jsonl")
    end

    test "overwrites existing file" do
      batch_id = "test_batch_#{:rand.uniform(100_000)}"

      # Create file with content
      {:ok, path} = BatchFile.create_file(batch_id)
      File.write!(path, "existing content")

      # Create again
      assert {:ok, ^path} = BatchFile.create_file(batch_id)
      assert File.read!(path) == ""
    end
  end
end
