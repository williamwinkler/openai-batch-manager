defmodule Batcher.Batching.Changes.UploadBatchFileTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "upload action (uses UploadBatchFile change)" do
    test "generates JSONL file and uploads to OpenAI", %{server: server} do
      batch = generate(batch())

      # Create a request
      {:ok, _request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_1",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_1",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      # Transition to uploading state
      {:ok, batch} = Batching.start_batch_upload(batch)

      # Mock file upload endpoint
      expect_json_response(server, :post, "/v1/files", %{"id" => "file-123"}, 200)

      # Upload batch file
      {:ok, updated_batch} =
        batch
        |> Ash.Changeset.for_update(:upload)
        |> Ash.update()

      assert updated_batch.openai_input_file_id == "file-123"
      assert updated_batch.state == :uploaded

      # Verify file was cleaned up
      batches_dir = Application.get_env(:batcher, :batches_dir, "./data/batches")
      batch_file_path = Path.join(batches_dir, "batch_#{batch.id}.jsonl")
      refute File.exists?(batch_file_path)
    end

    test "handles file upload failure", %{server: server} do
      batch = generate(batch())

      {:ok, _request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_1",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_1",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      {:ok, batch} = Batching.start_batch_upload(batch)

      # Mock file upload failure
      expect_json_response(server, :post, "/v1/files", %{"error" => "Upload failed"}, 400)

      result =
        batch
        |> Ash.Changeset.for_update(:upload)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "cleans up local file on success", %{server: server} do
      batch = generate(batch())

      {:ok, _request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_1",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_1",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      {:ok, batch} = Batching.start_batch_upload(batch)

      batches_dir = Application.get_env(:batcher, :batches_dir, "./data/batches")
      batch_file_path = Path.join(batches_dir, "batch_#{batch.id}.jsonl")

      expect_json_response(server, :post, "/v1/files", %{"id" => "file-123"}, 200)

      {:ok, _updated_batch} =
        batch
        |> Ash.Changeset.for_update(:upload)
        |> Ash.update()

      # File should be cleaned up
      refute File.exists?(batch_file_path)
    end

    test "handles file I/O errors gracefully", %{server: server} do
      batch = generate(batch())

      {:ok, _request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_1",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_1",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      {:ok, batch} = Batching.start_batch_upload(batch)

      # Mock file upload failure
      expect_json_response(server, :post, "/v1/files", %{"error" => "Upload failed"}, 400)

      result =
        batch
        |> Ash.Changeset.for_update(:upload)
        |> Ash.update()

      # Should fail with an error
      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "rejects empty batch file", %{server: _server} do
      # Create a batch with no requests
      batch = generate(batch())

      # Transition to uploading state
      {:ok, batch} = Batching.start_batch_upload(batch)

      # Attempt to upload - should fail because file is empty
      result =
        batch
        |> Ash.Changeset.for_update(:upload)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{} = error} = result

      # Verify the error message mentions empty file
      error_message = Exception.message(error)
      assert String.contains?(error_message, "empty") or String.contains?(error_message, "no requests")

      # Verify file was cleaned up
      batches_dir = Application.get_env(:batcher, :batches_dir, "./data/batches")
      batch_file_path = Path.join(batches_dir, "batch_#{batch.id}.jsonl")
      refute File.exists?(batch_file_path)
    end
  end
end
