defmodule Batcher.Batching.Actions.CancelBatchTest do
  use Batcher.DataCase, async: false
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching.BatchBuilder
  alias Batcher.Batching
  alias Oban.Job

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    Repo.delete_all(Job)
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

    test "terminates BatchBuilder when cancelling a building batch", %{server: _server} do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      request_data = %{
        custom_id: "cancel_builder_req",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request} = BatchBuilder.add_request(url, model, request_data)
      batch_before = Batching.get_batch_by_id!(request.batch_id)

      [{pid, _}] = Registry.lookup(Batcher.Batching.Registry, {url, model})
      assert Process.alive?(pid)

      {:ok, batch_after} = Batching.cancel_batch(batch_before)
      assert batch_after.state == :cancelled

      assert Registry.lookup(Batcher.Batching.Registry, {url, model}) == []
      refute Process.alive?(pid)
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

    test "cancels enqueued upload jobs for a batch and prevents queue drain progression", %{
      server: _server
    } do
      batch = generate(batch())
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model))

      {:ok, uploading_batch} = Batching.start_batch_upload(batch)
      assert uploading_batch.state == :uploading
      assert_enqueued(worker: Batcher.Batching.Batch.AshOban.Worker.UploadBatch)

      upload_job_before_cancel = find_upload_job_for_batch(uploading_batch.id)

      assert upload_job_before_cancel
      assert upload_job_before_cancel.state == "available"

      {:ok, cancelled_batch} = Batching.cancel_batch(uploading_batch)
      assert cancelled_batch.state == :cancelled

      upload_job_after_cancel = find_upload_job_for_batch(cancelled_batch.id)

      assert upload_job_after_cancel
      assert upload_job_after_cancel.state == "cancelled"

      Oban.drain_queue(queue: :batch_uploads)
      Oban.drain_queue(queue: :default)
      Oban.drain_queue(queue: :batch_processing)

      batch_after_drain = Batching.get_batch_by_id!(cancelled_batch.id)
      assert batch_after_drain.state == :cancelled
    end

    test "does not cancel requests when batch cancel fails", %{server: server} do
      openai_batch_id = "batch_cancel_failure_123"

      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          url: batch.url,
          model: batch.model,
          state: :pending
        )
        |> generate()

      expect_json_response(
        server,
        :post,
        "/v1/batches/#{openai_batch_id}/cancel",
        %{"error" => %{"message" => "Internal server error", "type" => "server_error"}},
        500
      )

      assert {:error, %Ash.Error.Invalid{} = error} = Batching.cancel_batch(batch)
      assert Exception.message(error) =~ "Failed to cancel OpenAI batch"

      assert Batching.get_batch_by_id!(batch.id).state == :openai_processing
      assert Batching.get_request_by_id!(request.id).state == :pending
    end
  end

  defp find_upload_job_for_batch(batch_id) do
    target_batch_id = Integer.to_string(batch_id)

    Repo.all(from job in Job, where: job.queue == "batch_uploads")
    |> Enum.find(fn job ->
      extracted_id =
        get_in(job.args, ["params", "primary_key", "id"]) ||
          get_in(job.args, ["primary_key", "id"]) ||
          get_in(job.args, [:params, :primary_key, :id]) ||
          get_in(job.args, [:primary_key, :id])

      "#{extracted_id}" == target_batch_id
    end)
  end
end
