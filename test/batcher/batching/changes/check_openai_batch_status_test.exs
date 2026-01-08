defmodule Batcher.Batching.Changes.CheckOpenaiBatchStatusTest do
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
    test "transitions batch to openai_completed when status is completed", %{server: server} do
      openai_batch_id = "batch_completed123"

      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "completed",
        "output_file_id" => "file-output123",
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
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :openai_completed
      assert batch_after.openai_output_file_id == "file-output123"
      assert batch_after.input_tokens == 1000
      assert batch_after.cached_tokens == 200
      assert batch_after.reasoning_tokens == 300
      assert batch_after.output_tokens == 800
    end

    test "transitions batch to failed when status is failed", %{server: server} do
      openai_batch_id = "batch_failed123"

      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "failed",
        "errors" => %{
          "message" => "Batch processing failed",
          "code" => "batch_failed"
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :failed
      assert batch_after.error_msg != nil
    end

    test "transitions batch to expired when status is expired", %{server: server} do
      openai_batch_id = "batch_expired123"

      batch =
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
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # expired status triggers mark_expired action
      assert batch_after.state == :expired
    end

    test "keeps batch in openai_processing for pending statuses", %{server: server} do
      openai_batch_id = "batch_validating123"

      batch =
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
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Pending statuses just update last_checked_at
      assert batch_after.state == :openai_processing
      assert batch_after.openai_status_last_checked_at != nil
    end

    test "returns error when API call fails", %{server: server} do
      openai_batch_id = "batch_api_error123"

      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

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
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert {:error, _} = result
    end
  end
end
