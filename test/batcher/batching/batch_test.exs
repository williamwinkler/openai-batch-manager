defmodule Batcher.Batching.BatchTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
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

  describe "Batcher.Batching.Batch.start_upload/0" do
    test "sets the state to :uploading" do
      batch = generate(batch())

      assert batch.state == :building

      result = Batching.start_batch_upload(batch)
      assert {:ok, updated_batch} = result
      assert updated_batch.state == :uploading

      # Verify that a transition record was created
      transitions = Batching.read_batch_by_id!(batch.id, load: [:transitions]).transitions
      assert transitions
      # building -> uploading
      assert length(transitions) == 2
      assert Enum.at(transitions, 1).from == :building
      assert Enum.at(transitions, 1).to == :uploading
      assert Enum.at(transitions, 1).transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.upload/0" do
    test "transitions batch from uploading to uploaded", %{server: server} do
      batch = generate(batch())
      generate(request(url: batch.url, batch_id: batch.id))

      batch = Batching.start_batch_upload!(batch, load: [:requests])

      assert batch.state == :uploading
      assert length(batch.requests) == 1

      response = %{
        "bytes" => 718,
        "created_at" => 1_766_068_446,
        "expires_at" => 1_768_660_446,
        "filename" => "batch_#{batch.id}.jsonl",
        "id" => "file-1quwTNE3rPZezkuRuGuXaS",
        "object" => "file",
        "purpose" => "batch",
        "status" => "processed",
        "status_details" => nil
      }

      expect_json_response(server, :post, "/v1/files", response, 200)

      # Perform the upload action
      updated_batch =
        batch
        |> Ash.Changeset.for_update(:upload)
        |> Ash.update!(load: [:transitions])

      # Verify the batch state and OpenAI file ID
      assert updated_batch.openai_input_file_id == response["id"]
      assert updated_batch.state == :uploaded

      # building -> uploading -> uploaded
      assert length(updated_batch.transitions) == 3

      assert Enum.at(updated_batch.transitions, 0).from == nil
      assert Enum.at(updated_batch.transitions, 0).to == :building

      assert Enum.at(updated_batch.transitions, 1).from == :building
      assert Enum.at(updated_batch.transitions, 1).to == :uploading

      assert Enum.at(updated_batch.transitions, 2).from == :uploading
      assert Enum.at(updated_batch.transitions, 2).to == :uploaded
    end
  end

  describe "Batcher.Batching.Batch.create_openai_batch/0" do
    test "transitions batch from uploaded to openai_processing", %{server: server} do
      openai_input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"
      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: openai_input_file_id))
      generate_many(request(batch_id: batch.id, url: batch.url), 5)

      response = %{
        # simplified response
        "id" => "batch_69442513cdb08190bc6dbfdfcd2b9b46",
      }

      expect_json_response(server, :post, "/v1/batches", response, 200)

      batch = batch
      |> Ash.Changeset.for_update(:create_openai_batch)
      |> Ash.update!(load: [:transitions, :requests])

      assert batch.state == :openai_processing
      assert batch.openai_batch_id == response["id"]

      latest_transition = List.last(batch.transitions)
      assert latest_transition.from == :uploaded
      assert latest_transition.to == :openai_processing
      assert latest_transition.transitioned_at

      # Verify the requests are in state :openai_processing as well
      for request <- batch.requests do
        assert request.state == :openai_processing
      end
    end
  end
end
