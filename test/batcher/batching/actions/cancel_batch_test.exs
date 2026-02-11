defmodule Batcher.Batching.Actions.CancelBatchTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "cancel_batch action" do
    test "successfully cancels batch in openai_processing state with openai_batch_id", %{
      server: server
    } do
      openai_batch_id = "batch_abc123"

      batch_before =
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

      # Cancel the batch using domain function
      {:ok, batch_after} = Batching.cancel_batch(batch_before)

      # Reload to check transitions
      batch_after = Ash.load!(batch_after, [:transitions])

      # Verify state transition
      assert batch_after.state == :cancelled

      # Verify transition record was created
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :cancelled
      assert latest_transition.transitioned_at
    end

    test "handles 404 response when batch already cancelled on OpenAI", %{server: server} do
      openai_batch_id = "batch_abc123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      # Mock 404 cancel response (batch not found - already cancelled)
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

      # Cancel should still succeed (404 is treated as success - batch already cancelled)
      {:ok, batch_after} = Batching.cancel_batch(batch_before)

      # Reload to check transitions
      batch_after = Ash.load!(batch_after, [:transitions])

      # Verify state transition still occurs
      assert batch_after.state == :cancelled

      # Verify transition record was created
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :cancelled
    end

    test "fails when API returns error response", %{server: server} do
      openai_batch_id = "batch_abc123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      # Mock error response
      cancel_response = %{
        "error" => %{
          "message" => "Internal server error",
          "type" => "server_error"
        }
      }

      expect_json_response(
        server,
        :post,
        "/v1/batches/#{openai_batch_id}/cancel",
        cancel_response,
        500
      )

      # Cancel should fail when API returns an error (other than 404)
      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               Batching.cancel_batch(batch_before)

      assert message =~ "Failed to cancel OpenAI batch"

      # Verify batch state was not changed
      batch_after = Batching.get_batch_by_id!(batch_before.id)
      assert batch_after.state == :openai_processing
    end

    test "does not call OpenAI API when batch has no openai_batch_id", %{server: _server} do
      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: nil
        )
        |> generate()

      # No API call should be made, so no need to mock

      # Cancel the batch
      {:ok, batch_after} = Batching.cancel_batch(batch_before)

      # Reload to check transitions
      batch_after = Ash.load!(batch_after, [:transitions])

      # Verify state transition still occurs
      assert batch_after.state == :cancelled

      # Verify transition record was created
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :cancelled
    end

    test "does not call OpenAI API when batch is not in openai_processing state", %{
      server: _server
    } do
      batch_before =
        seeded_batch(
          state: :building,
          openai_batch_id: "batch_abc123"
        )
        |> generate()

      # No API call should be made since state is not :openai_processing

      # Cancel the batch
      {:ok, batch_after} = Batching.cancel_batch(batch_before)

      # Reload to check transitions
      batch_after = Ash.load!(batch_after, [:transitions])

      # Verify state transition still occurs
      assert batch_after.state == :cancelled

      # Verify transition record was created
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :building
      assert latest_transition.to == :cancelled
    end

    test "can cancel batch from different valid states", %{server: server} do
      states = [:building, :uploading, :uploaded, :openai_processing]

      for state <- states do
        openai_batch_id = if state == :openai_processing, do: "batch_#{state}", else: nil

        batch_before =
          seeded_batch(
            state: state,
            openai_batch_id: openai_batch_id
          )
          |> generate()

        # Only mock API call for openai_processing state
        if state == :openai_processing do
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
        end

        # Cancel the batch
        {:ok, batch_after} = Batching.cancel_batch(batch_before)

        # Reload to check transitions
        batch_after = Ash.load!(batch_after, [:transitions])

        # Verify state transition
        assert batch_after.state == :cancelled

        # Verify transition record
        latest_transition = List.last(batch_after.transitions)
        assert latest_transition.from == state
        assert latest_transition.to == :cancelled
      end
    end

    test "creates transition record with correct timestamps", %{server: server} do
      openai_batch_id = "batch_abc123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

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

      before_time = DateTime.utc_now()

      {:ok, batch_after} = Batching.cancel_batch(batch_before)

      after_time = DateTime.utc_now()

      # Reload to check transitions
      batch_after = Ash.load!(batch_after, [:transitions])

      # Verify transition timestamp is within expected range
      latest_transition = List.last(batch_after.transitions)
      assert DateTime.compare(latest_transition.transitioned_at, before_time) != :lt
      assert DateTime.compare(latest_transition.transitioned_at, after_time) != :gt
    end

    test "cancels non-terminal requests when cancelling a batch", %{server: server} do
      openai_batch_id = "batch_with_requests_123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      pending_request =
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :pending
        )
        |> generate()

      processing_request =
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :openai_processing
        )
        |> generate()

      processed_request =
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :openai_processed
        )
        |> generate()

      delivering_request =
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :delivering
        )
        |> generate()

      delivered_request =
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :delivered
        )
        |> generate()

      failed_request =
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :failed
        )
        |> generate()

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

      {:ok, batch_after} = Batching.cancel_batch(batch_before)
      assert batch_after.state == :cancelled

      assert Batching.get_request_by_id!(pending_request.id).state == :cancelled
      assert Batching.get_request_by_id!(processing_request.id).state == :cancelled
      assert Batching.get_request_by_id!(processed_request.id).state == :cancelled
      assert Batching.get_request_by_id!(delivering_request.id).state == :cancelled

      assert Batching.get_request_by_id!(delivered_request.id).state == :delivered
      assert Batching.get_request_by_id!(failed_request.id).state == :failed
    end
  end
end
