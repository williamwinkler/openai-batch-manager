defmodule Batcher.Batching.Calculations.BatchSizeBytesTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching
  alias Batcher.Batching.Calculations.BatchSizeBytes

  import Batcher.Generator

  describe "calculate/3" do
    test "returns 0 for empty batch" do
      batch = generate(batch())

      result = BatchSizeBytes.calculate([batch], [], %{})

      # Ash.sum! returns nil for empty collections
      assert result == [nil]
    end

    test "returns correct size for single request" do
      batch = generate(batch())

      {:ok, request} =
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

      result = BatchSizeBytes.calculate([batch], [], %{})

      # Should equal the request's payload size
      assert result == [request.request_payload_size]
      assert hd(result) > 0
    end

    test "sums sizes correctly for multiple requests" do
      batch = generate(batch())

      # Create 3 requests and collect their sizes
      sizes =
        for i <- 1..3 do
          {:ok, request} =
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

          request.request_payload_size
        end

      result = BatchSizeBytes.calculate([batch], [], %{})

      expected_sum = Enum.sum(sizes)
      assert result == [expected_sum]
    end

    test "handles large payloads correctly" do
      batch = generate(batch())

      # Create request with large payload
      large_input = String.duplicate("x", 10_000)

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "large_req",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "large_req",
            body: %{input: large_input, model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      result = BatchSizeBytes.calculate([batch], [], %{})

      assert result == [request.request_payload_size]
      assert hd(result) > 10_000
    end

    test "returns updated size after request deletion" do
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

      {:ok, request2} =
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

      # Verify total size
      result = BatchSizeBytes.calculate([batch], [], %{})
      expected_total = request1.request_payload_size + request2.request_payload_size
      assert result == [expected_total]

      # Delete one request
      Ash.destroy!(request1)

      # Verify size is now just request2's size
      result = BatchSizeBytes.calculate([batch], [], %{})
      assert result == [request2.request_payload_size]
    end

    test "handles multiple batches correctly (isolation)" do
      batch1 = generate(batch())
      batch2 = generate(batch())

      # Add request to batch1
      {:ok, request1} =
        Batching.create_request(%{
          batch_id: batch1.id,
          custom_id: "batch1_req",
          url: batch1.url,
          model: batch1.model,
          request_payload: %{
            custom_id: "batch1_req",
            body: %{input: "test", model: batch1.model},
            method: "POST",
            url: batch1.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Add request to batch2
      {:ok, request2} =
        Batching.create_request(%{
          batch_id: batch2.id,
          custom_id: "batch2_req",
          url: batch2.url,
          model: batch2.model,
          request_payload: %{
            custom_id: "batch2_req",
            body: %{input: "test", model: batch2.model},
            method: "POST",
            url: batch2.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Calculate for both batches
      result = BatchSizeBytes.calculate([batch1, batch2], [], %{})

      assert result == [request1.request_payload_size, request2.request_payload_size]
    end
  end
end
