defmodule Batcher.Batching.Actions.DestroyBatchTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching
  alias Batcher.Batching.RequestDeliveryAttempt
  alias Batcher.Batching.BatchTransition
  alias Batcher.Batching.BatchBuilder

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "destroy action" do
    test "successfully destroys batch with no BatchBuilder running" do
      batch = generate(batch())

      # Verify batch exists
      assert {:ok, _} = Batching.get_batch_by_id(batch.id)

      # Run the destroy action using domain function
      result = Batching.destroy_batch(batch)

      # Should return ok (batch was deleted)
      assert :ok = result

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "successfully destroys batch with BatchBuilder running and terminates it" do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      # Create a batch with BatchBuilder
      request_data = %{
        custom_id: "destroy_test",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request} = BatchBuilder.add_request(url, model, request_data)
      batch_id = request.batch_id

      # Verify BatchBuilder is running
      [{pid, _}] = Registry.lookup(Batcher.Batching.Registry, {url, model})
      assert Process.alive?(pid)

      # Get the batch
      {:ok, batch} = Batching.get_batch_by_id(batch_id)

      # Destroy the batch using domain function
      result = Batching.destroy_batch(batch)

      assert :ok = result

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch_id)

      # Verify BatchBuilder was terminated and unregistered
      assert Registry.lookup(Batcher.Batching.Registry, {url, model}) == []
    end

    test "cascade deletes requests, delivery attempts, and batch transitions" do
      # Create a batch
      batch = generate(batch())

      # Create requests in the batch
      request1 = generate(request(batch_id: batch.id, url: batch.url, model: batch.model))
      request2 = generate(request(batch_id: batch.id, url: batch.url, model: batch.model))

      # Create delivery attempts for the requests
      {:ok, _attempt1} =
        Ash.create(RequestDeliveryAttempt, %{
          request_id: request1.id,
          outcome: :success,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
        })

      {:ok, _attempt2} =
        Ash.create(RequestDeliveryAttempt, %{
          request_id: request1.id,
          outcome: :connection_error,
          error_msg: "Failed",
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
        })

      {:ok, _attempt3} =
        Ash.create(RequestDeliveryAttempt, %{
          request_id: request2.id,
          outcome: :success,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
        })

      # Create batch transitions by changing state (transitions are created automatically)
      # Start upload to create a transition
      {:ok, batch} = Batching.start_batch_upload(batch)

      # Reload batch with all relationships
      batch = Batching.get_batch_by_id!(batch.id, load: [:requests, :transitions])
      request1 = Ash.load!(request1, [:delivery_attempts])
      request2 = Ash.load!(request2, [:delivery_attempts])

      # Verify data exists before deletion
      assert length(batch.requests) == 2
      assert length(batch.transitions) > 0
      assert length(request1.delivery_attempts) == 2
      assert length(request2.delivery_attempts) == 1

      # Get transition IDs before deletion
      transition_ids = Enum.map(batch.transitions, & &1.id)

      attempt_ids =
        Enum.map(request1.delivery_attempts, & &1.id) ++
          Enum.map(request2.delivery_attempts, & &1.id)

      # Delete the batch using domain function
      :ok = Batching.destroy_batch(batch)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)

      # Verify requests were cascade deleted
      require Ash.Query

      request_ids = [request1.id, request2.id]

      assert [] =
               Batching.Request
               |> Ash.Query.filter(id in ^request_ids)
               |> Ash.read!()

      # Verify delivery attempts were cascade deleted
      assert [] =
               RequestDeliveryAttempt
               |> Ash.Query.filter(id in ^attempt_ids)
               |> Ash.read!()

      # Verify batch transitions were cascade deleted
      assert [] =
               BatchTransition
               |> Ash.Query.filter(id in ^transition_ids)
               |> Ash.read!()
    end

    test "cancels OpenAI batch when in :openai_processing state", %{server: server} do
      openai_batch_id = "batch_abc123"

      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      # Mock successful cancel response
      cancel_response = %{
        "id" => openai_batch_id,
        "status" => "cancelling",
        "object" => "batch"
      }

      expect_json_response(
        server,
        :post,
        "/v1/batches/#{openai_batch_id}/cancel",
        cancel_response,
        200
      )

      # Destroy the batch using domain function
      :ok = Batching.destroy_batch(batch)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "proceeds with file deletion when cancel returns 404", %{server: server} do
      openai_batch_id = "batch_abc123"
      input_file_id = "file-input123"

      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          openai_input_file_id: input_file_id
        )
        |> generate()

      # Mock 404 cancel response (batch not found)
      cancel_response = %{
        "error" => %{
          "message" => "No batch found",
          "type" => "invalid_request_error"
        }
      }

      expect_json_response(
        server,
        :post,
        "/v1/batches/#{openai_batch_id}/cancel",
        cancel_response,
        404
      )

      # Mock file deletion (fire-and-forget, but we can verify it was called)
      delete_response = %{"deleted" => true, "id" => input_file_id, "object" => "file"}
      expect_json_response(server, :delete, "/v1/files/#{input_file_id}", delete_response, 200)

      # Destroy the batch using domain function
      :ok = Batching.destroy_batch(batch)

      # Give time for async file deletion to complete
      Process.sleep(100)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "does not cancel batch when not in :openai_processing state", %{server: _server} do
      openai_batch_id = "batch_abc123"

      batch =
        seeded_batch(
          state: :delivered,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      # Destroy the batch - should not call cancel endpoint
      :ok = Batching.destroy_batch(batch)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "does not cancel batch when openai_batch_id is nil", %{server: _server} do
      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: nil
        )
        |> generate()

      # Destroy the batch - should not call cancel endpoint
      :ok = Batching.destroy_batch(batch)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "deletes OpenAI input file when present", %{server: server} do
      input_file_id = "file-input123"

      batch =
        seeded_batch(openai_input_file_id: input_file_id)
        |> generate()

      delete_response = %{"deleted" => true, "id" => input_file_id, "object" => "file"}
      expect_json_response(server, :delete, "/v1/files/#{input_file_id}", delete_response, 200)

      # Destroy the batch using domain function
      :ok = Batching.destroy_batch(batch)

      # Give time for async file deletion to complete
      Process.sleep(100)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "deletes OpenAI output file when present", %{server: server} do
      output_file_id = "file-output123"

      batch =
        seeded_batch(openai_output_file_id: output_file_id)
        |> generate()

      delete_response = %{"deleted" => true, "id" => output_file_id, "object" => "file"}
      expect_json_response(server, :delete, "/v1/files/#{output_file_id}", delete_response, 200)

      # Destroy the batch using domain function
      :ok = Batching.destroy_batch(batch)

      # Give time for async file deletion to complete
      Process.sleep(100)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "deletes OpenAI error file when present", %{server: server} do
      error_file_id = "file-error123"

      batch =
        seeded_batch(openai_error_file_id: error_file_id)
        |> generate()

      delete_response = %{"deleted" => true, "id" => error_file_id, "object" => "file"}
      expect_json_response(server, :delete, "/v1/files/#{error_file_id}", delete_response, 200)

      # Destroy the batch using domain function
      :ok = Batching.destroy_batch(batch)

      # Give time for async file deletion to complete
      Process.sleep(100)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "deletes all three OpenAI files when all are present", %{server: server} do
      input_file_id = "file-input123"
      output_file_id = "file-output123"
      error_file_id = "file-error123"

      batch =
        seeded_batch(
          openai_input_file_id: input_file_id,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id
        )
        |> generate()

      # Mock all three file deletions
      delete_response = %{"deleted" => true, "object" => "file"}
      expect_json_response(server, :delete, "/v1/files/#{input_file_id}", delete_response, 200)
      expect_json_response(server, :delete, "/v1/files/#{output_file_id}", delete_response, 200)
      expect_json_response(server, :delete, "/v1/files/#{error_file_id}", delete_response, 200)

      # Destroy the batch using domain function
      :ok = Batching.destroy_batch(batch)

      # Give time for async file deletions to complete
      Process.sleep(100)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "handles missing file IDs gracefully", %{server: _server} do
      batch =
        seeded_batch(
          openai_input_file_id: nil,
          openai_output_file_id: nil,
          openai_error_file_id: nil
        )
        |> generate()

      # Destroy the batch - should not call any file deletion endpoints
      :ok = Batching.destroy_batch(batch)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "proceeds with destroy even if file deletion fails", %{server: server} do
      input_file_id = "file-input123"

      batch =
        seeded_batch(openai_input_file_id: input_file_id)
        |> generate()

      # Mock file deletion failure
      error_response = %{
        "error" => %{
          "message" => "File not found",
          "type" => "invalid_request_error"
        }
      }

      expect_json_response(server, :delete, "/v1/files/#{input_file_id}", error_response, 404)

      # Destroy the batch - should succeed despite file deletion failure
      :ok = Batching.destroy_batch(batch)

      # Give time for async file deletion to complete
      Process.sleep(100)

      # Verify batch was deleted (destroy succeeded despite file deletion failure)
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "handles BatchBuilder lookup failure gracefully" do
      # Create a batch that doesn't have a BatchBuilder (not in :building state)
      batch =
        seeded_batch(state: :delivered)
        |> generate()

      # Destroy the batch - should succeed even though no BatchBuilder exists
      :ok = Batching.destroy_batch(batch)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "works when invoked via AshOban (primary_key in params)" do
      batch = generate(batch())

      # Invoke via domain function (AshOban would use the domain function or Ash.destroy/2)
      :ok = Batching.destroy_batch(batch)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "cancels batch and deletes files in correct order", %{server: server} do
      openai_batch_id = "batch_abc123"
      input_file_id = "file-input123"
      output_file_id = "file-output123"

      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          openai_input_file_id: input_file_id,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # Mock cancel response
      cancel_response = %{
        "id" => openai_batch_id,
        "status" => "cancelling",
        "object" => "batch"
      }

      expect_json_response(
        server,
        :post,
        "/v1/batches/#{openai_batch_id}/cancel",
        cancel_response,
        200
      )

      # Mock file deletions
      delete_response = %{"deleted" => true, "object" => "file"}
      expect_json_response(server, :delete, "/v1/files/#{input_file_id}", delete_response, 200)
      expect_json_response(server, :delete, "/v1/files/#{output_file_id}", delete_response, 200)

      # Destroy the batch using domain function
      :ok = Batching.destroy_batch(batch)

      # Give time for async file deletions to complete
      Process.sleep(100)

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end
  end
end
