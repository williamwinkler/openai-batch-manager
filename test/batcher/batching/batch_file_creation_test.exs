defmodule Batcher.Batching.BatchFileCreationTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching
  alias Batcher.Batching.BatchFile

  setup do
    # Ensure directory exists (cleaned before test suite in test_helper.exs)
    BatchFile.ensure_directory_exists()
    :ok
  end

  describe "batch creation with file creation" do
    test "creates JSONL file when batch is created" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

      # File should exist
      file_path = BatchFile.file_path(batch.id)
      assert File.exists?(file_path)

      # File should be empty initially
      assert File.read!(file_path) == ""
    end

    test "file path follows naming convention" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

      file_path = BatchFile.file_path(batch.id)
      assert String.ends_with?(file_path, "batch_#{batch.id}.jsonl")
    end

    test "multiple batches create separate files" do
      {:ok, batch1} = Batching.create_batch(:openai, "gpt-4")
      {:ok, batch2} = Batching.create_batch(:openai, "gpt-3.5-turbo")

      file1 = BatchFile.file_path(batch1.id)
      file2 = BatchFile.file_path(batch2.id)

      assert File.exists?(file1)
      assert File.exists?(file2)
      assert file1 != file2
    end
  end

  describe "disk space validation" do
    test "batch creation succeeds when sufficient disk space" do
      # Assuming test environment has >10MB free
      assert {:ok, batch} = Batching.create_batch(:openai, "gpt-4")
      assert batch.id
    end

    # Note: Testing insufficient disk space is difficult without
    # mocking or creating a small test filesystem.
  end
end
