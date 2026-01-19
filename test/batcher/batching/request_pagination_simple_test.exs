defmodule Batcher.Batching.RequestPaginationSimpleTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching

  import Batcher.Generator

  describe "Batcher.Batching.Request.list_all_paginated - simple tests" do
    test "can query requests with pagination" do
      # Clean start - create fresh batch and requests
      batch = generate(batch())

      {:ok, _req1} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "test_1",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "test_1",
            body: %{input: "test1", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      query =
        Batching.Request
        |> Ash.Query.for_read(:list_all_paginated,
          skip: 0,
          limit: 25
        )

      result = Ash.read!(query, page: [offset: 0, limit: 25, count: true])

      assert result.count >= 1
      assert length(result.results) >= 1
    end

    test "search filters by custom_id" do
      batch = generate(batch())

      {:ok, req1} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "findme_unique_id",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "findme_unique_id",
            body: %{input: "test1", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Search for unique ID
      query =
        Batching.Request
        |> Ash.Query.for_read(:list_all_paginated,
          skip: 0,
          limit: 25,
          query: "findme_unique"
        )

      result = Ash.read!(query, page: [offset: 0, limit: 25, count: true])

      # Should find at least our request
      assert Enum.any?(result.results, fn r -> r.id == req1.id end)
    end

    test "sorting by custom_id works" do
      batch = generate(batch())

      {:ok, req_z} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "zzz_last",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "zzz_last",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
        })

      {:ok, req_a} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "aaa_first",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "aaa_first",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
        })

      # Sort ascending
      query =
        Batching.Request
        |> Ash.Query.for_read(:list_all_paginated,
          skip: 0,
          limit: 100,
          sort_by: "custom_id"
        )

      result = Ash.read!(query, page: [offset: 0, limit: 100, count: true])

      # Find positions of our test requests
      pos_a = Enum.find_index(result.results, fn r -> r.id == req_a.id end)
      pos_z = Enum.find_index(result.results, fn r -> r.id == req_z.id end)

      # aaa_first should come before zzz_last in ascending order
      assert pos_a < pos_z
    end
  end
end
