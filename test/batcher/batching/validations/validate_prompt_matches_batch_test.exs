defmodule Batcher.Batching.Validations.ValidatePromptMatchesBatchTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching
  import Batcher.BatchingFixtures

  describe "provider validation" do
    test "succeeds when prompt provider matches batch provider" do
      batch = batch_fixture(provider: :openai, model: "gpt-4")

      {:ok, prompt} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "test-1",
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook",
          provider: :openai,
          model: "gpt-4"
        })

      assert prompt.batch_id == batch.id
    end

    test "fails when prompt provider does not match batch provider" do
      batch = batch_fixture(provider: :openai, model: "gpt-4")

      # Note: Currently only :openai is supported, so this would fail at the enum level
      # This test documents the expected behavior if more providers were added
      {:error, error} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "test-2",
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook",
          provider: :anthropic,
          model: "gpt-4"
        })

      assert error.errors != []
    end
  end

  describe "model validation" do
    test "succeeds when prompt model matches batch model" do
      batch = batch_fixture(provider: :openai, model: "gpt-4")

      {:ok, prompt} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "test-3",
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook",
          provider: :openai,
          model: "gpt-4"
        })

      assert prompt.batch_id == batch.id
    end

    test "fails when prompt model does not match batch model" do
      batch = batch_fixture(provider: :openai, model: "gpt-4")

      {:error, error} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "test-4",
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook",
          provider: :openai,
          model: "gpt-3.5-turbo"
        })

      assert error.errors != []
      error_messages = Enum.map(error.errors, & &1.message)
      assert Enum.any?(error_messages, &String.contains?(&1, "Model"))
      assert Enum.any?(error_messages, &String.contains?(&1, "gpt-3.5-turbo"))
      assert Enum.any?(error_messages, &String.contains?(&1, "gpt-4"))
    end

    test "provides clear error message for model mismatch" do
      batch = batch_fixture(provider: :openai, model: "gpt-4")

      {:error, error} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "test-5",
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook",
          provider: :openai,
          model: "gpt-4o"
        })

      error_messages = Enum.map(error.errors, & &1.message)
      assert Enum.any?(error_messages, fn msg ->
        String.contains?(msg, "Model 'gpt-4o' does not match batch model 'gpt-4'")
      end)
    end
  end

  describe "batch_id validation" do
    test "fails when batch_id does not exist" do
      non_existent_id = 99999

      {:error, error} =
        Batching.create_prompt(%{
          batch_id: non_existent_id,
          custom_id: "test-6",
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook",
          provider: :openai,
          model: "gpt-4"
        })

      assert error.errors != []
      error_messages = Enum.map(error.errors, & &1.message)
      assert Enum.any?(error_messages, &String.contains?(&1, "Batch with id"))
      assert Enum.any?(error_messages, &String.contains?(&1, "not found"))
    end
  end

  describe "combined validation" do
    test "succeeds when both provider and model match" do
      batch = batch_fixture(provider: :openai, model: "gpt-4")

      {:ok, prompt} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "test-7",
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook",
          provider: :openai,
          model: "gpt-4"
        })

      assert prompt.batch_id == batch.id
    end

    test "allows creating multiple prompts with matching provider and model" do
      batch = batch_fixture(provider: :openai, model: "gpt-4")

      {:ok, _prompt1} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "test-8a",
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook1",
          provider: :openai,
          model: "gpt-4"
        })

      {:ok, _prompt2} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "test-8b",
          delivery_type: :rabbitmq,
          rabbitmq_queue: "queue1",
          provider: :openai,
          model: "gpt-4"
        })

      # Both should succeed since they match the batch
    end
  end

  describe "using fixtures" do
    test "fixtures automatically match batch provider and model" do
      batch = batch_fixture(provider: :openai, model: "gpt-4")

      # The fixture helper automatically sets provider and model from batch
      prompt = prompt_fixture(batch: batch)

      assert prompt.batch_id == batch.id
    end

    test "can create prompts with different delivery types but same provider/model" do
      batch = batch_fixture(provider: :openai, model: "gpt-4o")

      webhook_prompt = webhook_prompt_fixture(%{batch: batch})
      rabbitmq_prompt = rabbitmq_prompt_fixture(%{batch: batch})

      assert webhook_prompt.batch_id == batch.id
      assert rabbitmq_prompt.batch_id == batch.id
      assert webhook_prompt.delivery_type == :webhook
      assert rabbitmq_prompt.delivery_type == :rabbitmq
    end
  end
end
