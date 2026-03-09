defmodule Batcher.Batching.BatchCoreTest do
  use Batcher.DataCase, async: false
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching

  import Batcher.Generator

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "relationship loading" do
    test "loads batch.prompts relationship" do
      batch = generate(batch())

      # Create multiple requests
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

      # Load batch with requests (relationship is called :requests, not :prompts)
      batch = Ash.load!(batch, [:requests])

      assert length(batch.requests) == 2
      assert Enum.any?(batch.requests, &(&1.custom_id == req1.custom_id))
      assert Enum.any?(batch.requests, &(&1.custom_id == req2.custom_id))
    end

    test "loads batch.transitions relationship" do
      batch = generate(batch())

      # Load transitions
      batch = Ash.load!(batch, [:transitions])

      # Should have initial transition (nil → :building)
      assert length(batch.transitions) == 1
      transition = List.first(batch.transitions)
      assert transition.from == nil
      assert transition.to == :building
      assert transition.batch_id == batch.id

      # Add a request before transitioning (empty batches cannot be uploaded)
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model))
      batch = Batching.get_batch_by_id!(batch.id)

      # Transition to uploading
      {:ok, batch} = Batching.start_batch_upload(batch)
      batch = Ash.load!(batch, [:transitions])

      # Should have 2 transitions now
      assert length(batch.transitions) == 2
    end

    test "loads nested relationships" do
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

      # Load batch with requests and transitions
      batch = Ash.load!(batch, [:requests, :transitions])

      assert length(batch.requests) == 1
      assert length(batch.transitions) == 1
    end
  end

  describe "Batcher.Batching.create_batch/2" do
    @test_cases Batching.Types.OpenaiBatchEndpoints.values()
                |> Enum.map(fn url ->
                  %{url: url, model: Batcher.Models.model(url)}
                end)

    for test_case <- @test_cases do
      test "create a batch for #{test_case.url} with model #{test_case.model}" do
        model = unquote(test_case.model)
        url = unquote(test_case.url)

        batch = Batching.create_batch!(model, url)

        assert is_integer(batch.id)
        assert batch.state == :building
        assert batch.created_at
        assert batch.updated_at
        assert batch.url == url
        assert batch.model == model
      end
    end

    test "can't create batch with invalid url" do
      assert_raise Ash.Error.Invalid, fn ->
        Batching.create_batch!("gpt-4o-mini", "/v1/invalid-endpoint")
      end
    end

    test "can't create batch with empty model" do
      assert_raise Ash.Error.Invalid, fn ->
        Batching.create_batch!("", "/v1/responses")
      end
    end
  end

  describe "Batcher.Batching.find_build_batch/2" do
    test "finds existing building batch" do
      model = "gpt-4.1-mini"
      url = "/v1/responses"

      # Create a building batch
      batch1 = Batching.create_batch!(model, url)

      # Add a batch in a different state to ensure it is not returned
      generate(seeded_batch(model: model, url: url, state: :uploading))
      generate(seeded_batch(model: model, url: url, state: :openai_processing))
      generate(seeded_batch(model: model, url: url, state: :cancelled))
      generate(batch(model: "different-model", url: url))
      generate(batch(model: model, url: "/v1/chat/completions"))

      building_batch = Batching.find_building_batch!(model, url)

      assert building_batch
      assert building_batch.state == :building
      assert building_batch.id == batch1.id
    end

    test "throws error if no building batch exists" do
      model = "gpt-4.1-mini"
      url = "/v1/responses"

      assert_raise Ash.Error.Invalid, fn ->
        Batching.find_building_batch!(model, url)
      end
    end
  end

  describe "Batcher.Batching.count_batches_for_search" do
    test "counts batches using the same query semantics as search" do
      _ = generate(batch(model: "count-model-a"))
      _ = generate(batch(model: "count-model-b"))
      _ = generate(batch(model: "other-model"))

      {:ok, page} = Batching.search_batches("count-model", page: [limit: 1, count: true])

      {:ok, count_page} =
        Batching.count_batches_for_search("count-model", page: [limit: 1, count: true])

      assert count_page.count == page.count
      assert count_page.count == 2
    end
  end
end
