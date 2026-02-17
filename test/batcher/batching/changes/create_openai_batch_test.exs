defmodule Batcher.Batching.Changes.CreateOpenaiBatchTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching
  alias Batcher.Settings

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "create_openai_batch action (uses CreateOpenaiBatch change)" do
    test "creates OpenAI batch and assigns openai_batch_id", %{server: server} do
      # Start with uploaded state (after file upload)
      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: "file-123"))

      openai_response = %{
        "id" => "batch_abc123",
        "status" => "validating",
        "input_file_id" => "file-123"
      }

      expect_json_response(server, :post, "/v1/batches", openai_response, 200)

      {:ok, updated_batch} =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      assert updated_batch.openai_batch_id == "batch_abc123"
      assert updated_batch.state == :openai_processing
    end

    test "bulk updates requests to processing state after batch creation", %{server: server} do
      # Create batch in building state first to add requests
      batch = generate(batch())

      # Create 3 pending requests while batch is in building state
      {:ok, req1} =
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
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      {:ok, req2} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_2",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_2",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      {:ok, req3} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_3",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_3",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Verify initial state
      assert req1.state == :pending
      assert req2.state == :pending
      assert req3.state == :pending

      # Transition batch through states to uploaded (simulating workflow)
      {:ok, batch} = Batching.start_batch_upload(batch)

      # Mock file upload endpoint (expires_at is 30 days from now)
      expires_at = System.os_time(:second) + 30 * 24 * 60 * 60

      expect_json_response(
        server,
        :post,
        "/v1/files",
        %{"id" => "file-123", "expires_at" => expires_at},
        200
      )

      # Upload batch file using the action directly
      {:ok, batch} =
        batch
        |> Ash.Changeset.for_update(:upload)
        |> Ash.update()

      openai_response = %{
        "id" => "batch_abc123",
        "status" => "validating",
        "input_file_id" => "file-123"
      }

      expect_json_response(server, :post, "/v1/batches", openai_response, 200)

      {:ok, _updated_batch} =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      # Reload requests to check their state
      {:ok, updated_req1} = Batching.get_request_by_custom_id(batch.id, req1.custom_id)
      {:ok, updated_req2} = Batching.get_request_by_custom_id(batch.id, req2.custom_id)
      {:ok, updated_req3} = Batching.get_request_by_custom_id(batch.id, req3.custom_id)

      assert updated_req1.state == :openai_processing
      assert updated_req2.state == :openai_processing
      assert updated_req3.state == :openai_processing
    end

    test "handles OpenAI API failure", %{server: server} do
      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: "file-123"))

      error_response = %{
        "error" => %{
          "message" => "Invalid file ID",
          "type" => "invalid_request_error"
        }
      }

      expect_json_response(server, :post, "/v1/batches", error_response, 400)

      # The change module will add an error, which will make the update fail
      result =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      # Should fail with an error
      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "moves to waiting_for_capacity with insufficient_headroom when capacity is exhausted" do
      model = "gpt-4o-mini"

      _active_reserved =
        generate(
          seeded_batch(
            model: model,
            state: :openai_processing,
            estimated_input_tokens_total: 1_950_000
          )
        )

      batch =
        generate(
          seeded_batch(
            model: model,
            state: :uploaded,
            openai_input_file_id: "file-123",
            estimated_input_tokens_total: 100_000
          )
        )

      result =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result

      updated = Batching.get_batch_by_id!(batch.id)
      assert updated.state == :waiting_for_capacity
      assert updated.capacity_wait_reason == "insufficient_headroom"
    end

    test "uses settings override limit when deciding admission", %{server: server} do
      model = "gpt-4o-mini"
      _ = Settings.upsert_model_override!(model, 2_100_000)

      _active_reserved =
        generate(
          seeded_batch(
            model: model,
            state: :openai_processing,
            estimated_input_tokens_total: 1_950_000
          )
        )

      batch =
        generate(
          seeded_batch(
            model: model,
            state: :uploaded,
            openai_input_file_id: "file-123",
            estimated_input_tokens_total: 100_000
          )
        )

      openai_response = %{
        "id" => "batch_abc123",
        "status" => "validating",
        "input_file_id" => "file-123"
      }

      expect_json_response(server, :post, "/v1/batches", openai_response, 200)

      {:ok, updated_batch} =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      assert updated_batch.state == :openai_processing
      assert updated_batch.openai_batch_id == "batch_abc123"
    end

    test "only updates pending requests to processing", %{server: server} do
      # Create batch in building state, add requests
      batch = generate(batch())

      # Create pending request while batch is in building state
      {:ok, pending_req} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "pending_req",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "pending_req",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Create request already in processing state
      processing_req =
        generate(
          seeded_request(
            batch_id: batch.id,
            state: :openai_processing,
            custom_id: "processing_req"
          )
        )

      # Transition batch through states to uploaded (simulating workflow)
      {:ok, batch} = Batching.start_batch_upload(batch)

      # Mock file upload endpoint (expires_at is 30 days from now)
      expires_at = System.os_time(:second) + 30 * 24 * 60 * 60

      expect_json_response(
        server,
        :post,
        "/v1/files",
        %{"id" => "file-123", "expires_at" => expires_at},
        200
      )

      # Upload batch file using the action directly
      {:ok, batch} =
        batch
        |> Ash.Changeset.for_update(:upload)
        |> Ash.update()

      openai_response = %{
        "id" => "batch_abc123",
        "status" => "validating",
        "input_file_id" => "file-123"
      }

      expect_json_response(server, :post, "/v1/batches", openai_response, 200)

      {:ok, _updated_batch} =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      # Pending request should be updated
      {:ok, updated_pending} = Batching.get_request_by_custom_id(batch.id, pending_req.custom_id)
      assert updated_pending.state == :openai_processing

      # Processing request should remain unchanged
      {:ok, updated_processing} =
        Batching.get_request_by_custom_id(batch.id, processing_req.custom_id)

      assert updated_processing.state == :openai_processing
    end

    test "handles OpenAI API timeout error" do
      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: "file-123"))

      # Use invalid URL to cause connection timeout
      original_url = Process.get(:openai_base_url)
      Process.put(:openai_base_url, "http://192.0.2.1:9999/v1")

      result =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      # Restore original URL
      Process.put(:openai_base_url, original_url)

      # Should fail with timeout/network error
      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "handles OpenAI API network error" do
      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: "file-123"))

      # Use invalid URL to cause network error
      original_url = Process.get(:openai_base_url)
      Process.put(:openai_base_url, "http://invalid-host-that-does-not-exist:9999")

      result =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      # Restore original URL
      Process.put(:openai_base_url, original_url)

      # Should fail with network error
      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "handles OpenAI API error with nested error structure", %{server: server} do
      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: "file-123"))

      error_response = %{
        "error" => %{
          "message" => "Invalid file format",
          "type" => "invalid_request_error",
          "param" => "input_file_id",
          "code" => "invalid_file"
        }
      }

      expect_json_response(server, :post, "/v1/batches", error_response, 400)

      result =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "handles OpenAI API error with string message", %{server: server} do
      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: "file-123"))

      error_response = %{
        "error" => "File not found"
      }

      expect_json_response(server, :post, "/v1/batches", error_response, 404)

      result =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "handles bulk update when no pending requests exist", %{server: server} do
      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: "file-123"))

      # Batch has no requests
      openai_response = %{
        "id" => "batch_abc123",
        "status" => "validating",
        "input_file_id" => "file-123"
      }

      expect_json_response(server, :post, "/v1/batches", openai_response, 200)

      {:ok, updated_batch} =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update()

      # Should succeed even with no requests to update
      assert updated_batch.openai_batch_id == "batch_abc123"
      assert updated_batch.state == :openai_processing
    end
  end
end
