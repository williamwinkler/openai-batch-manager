defmodule Batcher.Batching.Calculations.BatchRequestCountTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching
  alias Batcher.Batching.Calculations.BatchRequestCount

  import Batcher.Generator

  describe "calculate/3" do
    test "returns 0 for empty batch" do
      batch = generate(batch())

      result = BatchRequestCount.calculate([batch], [], %{})

      assert result == [0]
    end

    test "returns 1 for batch with single request" do
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
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      result = BatchRequestCount.calculate([batch], [], %{})

      assert result == [1]
    end

    test "returns correct count for multiple requests" do
      batch = generate(batch())

      # Create 5 requests
      for i <- 1..5 do
        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: "req_#{i}",
            url: batch.url,
            model: batch.model,
            request_payload: %{
              custom_id: "req_#{i}",
              body: %{input: "test #{i}", model: batch.model},
              method: "POST",
              url: batch.url
            },
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      result = BatchRequestCount.calculate([batch], [], %{})

      assert result == [5]
    end

    test "returns updated count after request deletion" do
      batch = generate(batch())

      {:ok, request1} =
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

      {:ok, _request2} =
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

      # Verify count is 2
      result = BatchRequestCount.calculate([batch], [], %{})
      assert result == [2]

      # Delete one request
      Ash.destroy!(request1)

      # Verify count is now 1
      result = BatchRequestCount.calculate([batch], [], %{})
      assert result == [1]
    end

    test "handles multiple batches correctly (isolation)" do
      batch1 = generate(batch())
      batch2 = generate(batch())

      # Add 3 requests to batch1
      for i <- 1..3 do
        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch1.id,
            custom_id: "batch1_req_#{i}",
            url: batch1.url,
            model: batch1.model,
            request_payload: %{
              custom_id: "batch1_req_#{i}",
              body: %{input: "test", model: batch1.model},
              method: "POST",
              url: batch1.url
            },
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      # Add 2 requests to batch2
      for i <- 1..2 do
        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch2.id,
            custom_id: "batch2_req_#{i}",
            url: batch2.url,
            model: batch2.model,
            request_payload: %{
              custom_id: "batch2_req_#{i}",
              body: %{input: "test", model: batch2.model},
              method: "POST",
              url: batch2.url
            },
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      # Calculate for both batches
      result = BatchRequestCount.calculate([batch1, batch2], [], %{})

      assert result == [3, 2]
    end
  end
end
