defmodule Batcher.Batching.RequestQueryingTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching
  import Batcher.Generator

  describe "Batcher.Batching.get_request_by_custom_id" do
    test "finds request by batch_id and custom_id" do
      batch = generate(batch())
      custom_id = "find_me"

      {:ok, created_request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: custom_id,
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: custom_id,
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      found_request = Batching.get_request_by_custom_id!(batch.id, custom_id)

      assert found_request.id == created_request.id
      assert found_request.custom_id == custom_id
      assert found_request.batch_id == batch.id
    end

    test "throws error if request not found" do
      batch = generate(batch())

      assert_raise Ash.Error.Invalid, fn ->
        Batching.get_request_by_custom_id!(batch.id, "nonexistent")
      end
    end
  end

  describe "Batcher.Batching.list_requests_in_batch" do
    test "lists all requests in a batch" do
      batch1 = generate(batch())
      batch2 = generate(batch())

      # Create requests in batch1
      {:ok, _req1} =
        Batching.create_request(%{
          batch_id: batch1.id,
          custom_id: "req1",
          url: batch1.url,
          model: batch1.model,
          request_payload: %{
            custom_id: "req1",
            body: %{input: "test1", model: batch1.model},
            method: "POST",
            url: batch1.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      {:ok, _req2} =
        Batching.create_request(%{
          batch_id: batch1.id,
          custom_id: "req2",
          url: batch1.url,
          model: batch1.model,
          request_payload: %{
            custom_id: "req2",
            body: %{input: "test2", model: batch1.model},
            method: "POST",
            url: batch1.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Create request in batch2
      {:ok, _req3} =
        Batching.create_request(%{
          batch_id: batch2.id,
          custom_id: "req3",
          url: batch2.url,
          model: batch2.model,
          request_payload: %{
            custom_id: "req3",
            body: %{input: "test3", model: batch2.model},
            method: "POST",
            url: batch2.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      {:ok, requests} = Batching.list_requests_in_batch(batch1.id)

      assert length(requests) == 2
      assert Enum.all?(requests, fn req -> req.batch_id == batch1.id end)
    end

    test "returns empty list for batch with no requests" do
      batch = generate(batch())

      {:ok, requests} = Batching.list_requests_in_batch(batch.id)

      assert requests == []
    end
  end

  describe "Batcher.Batching.count_requests_for_search" do
    test "counts requests using the same query semantics as search" do
      batch = generate(batch())

      for i <- 1..3 do
        {:ok, _request} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: "needle-#{i}",
            url: batch.url,
            model: batch.model,
            request_payload: %{
              custom_id: "needle-#{i}",
              body: %{input: "count test", model: batch.model},
              method: "POST",
              url: batch.url
            },
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      {:ok, page} = Batching.search_requests("needle-", page: [limit: 2, count: true])

      {:ok, count_page} =
        Batching.count_requests_for_search("needle-", page: [limit: 1, count: true])

      assert count_page.count == page.count
    end

    test "respects batch_id filtering" do
      batch1 = generate(batch())
      batch2 = generate(batch())

      _ = generate_many(request(batch_id: batch1.id), 2)
      _ = generate_many(request(batch_id: batch2.id), 4)

      {:ok, page} =
        Batching.search_requests(
          "",
          %{batch_id: batch2.id, sort_input: "-created_at"},
          page: [limit: 2, count: true]
        )

      {:ok, count_page} =
        Batching.count_requests_for_search(
          "",
          %{batch_id: batch2.id},
          page: [limit: 1, count: true]
        )

      assert count_page.count == page.count
      assert count_page.count == 4
    end

    test "supports created_before filtering consistently for search and count" do
      batch = generate(batch())

      older_request =
        generate(
          seeded_request(
            batch_id: batch.id,
            custom_id: "created-before-older",
            url: batch.url,
            model: batch.model
          )
        )

      Process.sleep(5)

      newer_request =
        generate(
          seeded_request(
            batch_id: batch.id,
            custom_id: "created-before-newer",
            url: batch.url,
            model: batch.model
          )
        )

      cutoff = older_request.created_at

      {:ok, page} =
        Batching.search_requests(
          "created-before-",
          %{created_before: cutoff, sort_input: "-created_at"},
          page: [limit: 10, count: true]
        )

      {:ok, count_page} =
        Batching.count_requests_for_search(
          "created-before-",
          %{created_before: cutoff},
          page: [limit: 1, count: true]
        )

      ids = Enum.map(page.results, & &1.id)

      assert older_request.id in ids
      refute newer_request.id in ids
      assert count_page.count == 1
    end

    test "supports failed_any filtering consistently for search and count" do
      batch = generate(batch())

      openai_failed =
        generate(
          seeded_request(
            batch_id: batch.id,
            custom_id: "failed-any-openai",
            url: batch.url,
            model: batch.model,
            state: :failed
          )
        )

      delivery_failed =
        generate(
          seeded_request(
            batch_id: batch.id,
            custom_id: "failed-any-delivery",
            url: batch.url,
            model: batch.model,
            state: :delivery_failed,
            response_payload: %{"ok" => true}
          )
        )

      _delivered =
        generate(
          seeded_request(
            batch_id: batch.id,
            custom_id: "failed-any-delivered",
            url: batch.url,
            model: batch.model,
            state: :delivered,
            response_payload: %{"ok" => true}
          )
        )

      {:ok, page} =
        Batching.search_requests(
          "failed-any-",
          %{state_filter: "failed_any", sort_input: "-created_at"},
          page: [limit: 10, count: true]
        )

      {:ok, count_page} =
        Batching.count_requests_for_search(
          "failed-any-",
          %{state_filter: "failed_any"},
          page: [limit: 1, count: true]
        )

      ids = Enum.map(page.results, & &1.id)

      assert openai_failed.id in ids
      assert delivery_failed.id in ids
      assert count_page.count == 2
    end
  end
end
