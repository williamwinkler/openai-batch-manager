defmodule Batcher.Batching.Actions.CheckBatchStatusTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "check_batch_status action" do
    test "transitions to openai_completed when status is completed", %{server: server} do
      openai_batch_id = "batch_69442513cdb08190bc6dbfdfcd2b9b46"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_input_file_id: "file-1quwTNE3rPZezkuRuGuXaS",
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "completed",
        "output_file_id" => "file-2AbcDNE3rPZezkuRuGuXbB",
        "usage" => %{
          "input_tokens" => 1000,
          "input_tokens_details" => %{"cached_tokens" => 200},
          "output_tokens_details" => %{"reasoning_tokens" => 300},
          "output_tokens" => 800
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:transitions])

      assert batch_after.state == :openai_completed
      assert batch_after.openai_output_file_id == response["output_file_id"]
      assert batch_after.openai_status_last_checked_at
      assert batch_after.input_tokens == 1000
      assert batch_after.cached_tokens == 200
      assert batch_after.reasoning_tokens == 300
      assert batch_after.output_tokens == 800

      # Verify transition record
      assert length(batch_after.transitions) == 1
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :openai_completed
    end

    test "transitions to failed when status is failed", %{server: server} do
      openai_batch_id = "batch_failed123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "failed",
        "error" => %{
          "message" => "Batch processing failed",
          "code" => "batch_failed"
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:transitions])

      assert batch_after.state == :failed
      assert batch_after.openai_status_last_checked_at

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :failed
    end

    test "transitions to failed when status is expired", %{server: server} do
      openai_batch_id = "batch_expired123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "expired"
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:transitions])

      assert batch_after.state == :failed
      assert batch_after.openai_status_last_checked_at

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :failed
    end

    test "updates last_checked_at without state change when status is pending", %{server: server} do
      openai_batch_id = "batch_pending123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "validating"
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # State should remain unchanged
      assert batch_after.state == :openai_processing
      assert batch_after.openai_status_last_checked_at
      assert batch_after.openai_status_last_checked_at != nil
    end

    test "handles API failures gracefully", %{server: server} do
      openai_batch_id = "batch_error123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      # Mock API failure
      expect_json_response(
        server,
        :get,
        "/v1/batches/#{openai_batch_id}",
        %{"error" => "Not found"},
        404
      )

      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Should return error
      assert {:error, _} = result
    end

    test "extracts and assigns token usage correctly", %{server: server} do
      openai_batch_id = "batch_tokens123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "completed",
        "output_file_id" => "file-output123",
        "usage" => %{
          "input_tokens" => 5000,
          "input_tokens_details" => %{"cached_tokens" => 1000},
          "output_tokens_details" => %{"reasoning_tokens" => 500},
          "output_tokens" => 2000
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      assert batch_after.input_tokens == 5000
      assert batch_after.cached_tokens == 1000
      assert batch_after.reasoning_tokens == 500
      assert batch_after.output_tokens == 2000
    end
  end
end
