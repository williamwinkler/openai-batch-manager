defmodule Batcher.BatchingFixtures do
  @moduledoc """
  This module defines test helpers for creating entities via the Batcher.Batching domain.

  These fixtures make it easy to set up test data without repeating boilerplate code.
  All fixtures use the domain's code interface to ensure they follow the same
  business rules as production code.
  """

  alias Batcher.Batching

  @doc """
  Creates a batch with default or custom attributes.

  ## Examples

      # Create with defaults
      batch = batch_fixture()

      # Create with custom provider and model
      batch = batch_fixture(provider: :openai, model: "gpt-4o")

      # Create in a specific state
      batch = batch_fixture(state: :ready_for_upload)
  """
  def batch_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    model = attrs[:model] || "gpt-4o-mini"
    endpoint = attrs[:endpoint] || "/v1/responses"

    {:ok, batch} = Batching.create_batch(model, endpoint)

    # If a specific state is requested, transition to it
    batch =
      case attrs[:state] do
        nil -> batch
        :draft -> batch
        state -> transition_batch_to_state(batch, state)
      end

    batch
  end

  @doc """
  Creates a prompt attached to a batch with default or custom attributes.

  ## Examples

      # Create with defaults (webhook delivery)
      prompt = prompt_fixture()

      # Create with custom batch
      batch = batch_fixture()
      prompt = prompt_fixture(batch: batch)

      # Create with RabbitMQ delivery
      prompt = prompt_fixture(delivery_type: :rabbitmq, rabbitmq_queue: "my_queue")

      # Create in a specific state
      prompt = prompt_fixture(state: :processing)
  """
  def prompt_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    # Create or use provided batch
    batch = attrs[:batch] || batch_fixture()

    # Build prompt attributes
    custom_id = attrs[:custom_id] || Ecto.UUID.generate()
    delivery_type = attrs[:delivery_type] || :webhook

    # Build delivery config based on type
    delivery_attrs =
      case delivery_type do
        :webhook ->
          %{
            delivery_type: :webhook,
            webhook_url: attrs[:webhook_url] || "https://example.com/webhook/#{custom_id}"
          }

        :rabbitmq ->
          %{
            delivery_type: :rabbitmq,
            rabbitmq_queue: attrs[:rabbitmq_queue] || "results_queue"
          }
      end

    # Merge all attributes and arguments
    # Note: endpoint and model come from batch
    base_params = %{
      batch_id: batch.id,
      custom_id: custom_id,
      endpoint: batch.endpoint,
      model: batch.model,
      request_payload: attrs[:request_payload] || %{"test" => "data"}
    }

    # Add tag if provided
    base_params = if Map.has_key?(attrs, :tag), do: Map.put(base_params, :tag, attrs[:tag]), else: base_params

    prompt_params = Map.merge(delivery_attrs, base_params)

    {:ok, prompt} = Batching.create_prompt(prompt_params)

    # If a specific state is requested, transition to it
    prompt =
      case attrs[:state] do
        nil -> prompt
        :pending -> prompt
        state -> transition_prompt_to_state(prompt, state)
      end

    prompt
  end

  @doc """
  Creates a batch with associated prompts.

  ## Examples

      # Create batch with 3 default prompts
      {batch, prompts} = batch_with_prompts_fixture(prompt_count: 3)

      # Create batch with custom prompts
      {batch, prompts} = batch_with_prompts_fixture(
        prompt_count: 2,
        prompt_attrs: [
          [delivery_type: :webhook],
          [delivery_type: :rabbitmq, rabbitmq_queue: "queue1"]
        ]
      )
  """
  def batch_with_prompts_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    batch = batch_fixture(Map.take(attrs, [:endpoint, :model, :state]))

    prompt_count = attrs[:prompt_count] || 1
    prompt_attrs_list = attrs[:prompt_attrs] || List.duplicate(%{}, prompt_count)

    prompts =
      prompt_attrs_list
      |> Enum.with_index()
      |> Enum.map(fn {prompt_attrs, index} ->
        # Convert to map if needed and ensure unique custom_id
        prompt_attrs = if is_list(prompt_attrs), do: Map.new(prompt_attrs), else: prompt_attrs
        prompt_attrs = Map.put_new(prompt_attrs, :custom_id, "prompt-#{batch.id}-#{index}")

        prompt_fixture(Map.put(prompt_attrs, :batch, batch))
      end)

    {batch, prompts}
  end

  @doc """
  Creates a webhook delivery prompt (shorthand).
  """
  def webhook_prompt_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    attrs =
      attrs
      |> Map.put(:delivery_type, :webhook)
      |> Map.put_new(:webhook_url, "https://example.com/webhook/#{Ecto.UUID.generate()}")

    prompt_fixture(attrs)
  end

  @doc """
  Creates a RabbitMQ delivery prompt (shorthand).
  """
  def rabbitmq_prompt_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    attrs =
      attrs
      |> Map.put(:delivery_type, :rabbitmq)
      |> Map.put_new(:rabbitmq_queue, "results_queue")

    prompt_fixture(attrs)
  end

  # Transition batch through states to reach target state
  defp transition_batch_to_state(batch, target_state) do
    state_sequence = [
      :draft,
      :ready_for_upload,
      :uploading,
      :validating,
      :in_progress,
      :finalizing,
      :downloading,
      :completed
    ]

    current_index = Enum.find_index(state_sequence, &(&1 == batch.state))
    target_index = Enum.find_index(state_sequence, &(&1 == target_state))

    cond do
      # Terminal/error states
      target_state == :failed ->
        # Can fail from various states, use in_progress
        batch = transition_batch_to_state(batch, :in_progress)
        {:ok, batch} = Batching.batch_mark_failed(batch)
        batch

      target_state == :cancelled ->
        {:ok, batch} = Batching.batch_cancel(batch)
        batch

      target_state == :expired ->
        # Expired is only from validating, in_progress, or finalizing
        batch = transition_batch_to_state(batch, :in_progress)
        {:ok, batch} = Batching.batch_mark_expired(batch)
        batch

      # Sequential transitions
      target_index > current_index ->
        # Transition step by step
        Enum.reduce((current_index + 1)..target_index, batch, fn index, acc_batch ->
          next_state = Enum.at(state_sequence, index)
          transition_batch_one_step(acc_batch, next_state)
        end)

      true ->
        batch
    end
  end

  defp transition_batch_one_step(batch, target_state) do
    case target_state do
      :ready_for_upload ->
        {:ok, batch} = Batching.batch_mark_ready(batch)
        batch

      :uploading ->
        {:ok, batch} = Batching.batch_begin_upload(batch)
        batch

      :validating ->
        # This action requires openai_batch_id attribute as a map
        {:ok, batch} =
          Batching.batch_mark_validating(batch, %{
            openai_batch_id: "batch_#{Ecto.UUID.generate()}"
          })

        batch

      :in_progress ->
        {:ok, batch} = Batching.batch_mark_in_progress(batch)
        batch

      :finalizing ->
        {:ok, batch} = Batching.batch_mark_finalizing(batch)
        batch

      :downloading ->
        {:ok, batch} = Batching.batch_begin_download(batch)
        batch

      :completed ->
        {:ok, batch} = Batching.batch_mark_completed(batch)
        batch

      _ ->
        batch
    end
  end

  # Transition prompt through states to reach target state
  defp transition_prompt_to_state(prompt, target_state) do
    state_sequence = [:pending, :processing, :processed, :delivering, :delivered]

    current_index = Enum.find_index(state_sequence, &(&1 == prompt.state))
    target_index = Enum.find_index(state_sequence, &(&1 == target_state))

    cond do
      # Terminal/error states
      target_state == :failed ->
        # Can fail from processing
        prompt = transition_prompt_to_state(prompt, :processing)
        {:ok, prompt} = Batching.prompt_mark_failed(prompt)
        prompt

      target_state == :cancelled ->
        {:ok, prompt} = Batching.prompt_cancel(prompt)
        prompt

      target_state == :expired ->
        {:ok, prompt} = Batching.prompt_mark_expired(prompt)
        prompt

      # Sequential transitions
      target_index > current_index ->
        Enum.reduce((current_index + 1)..target_index, prompt, fn index, acc_prompt ->
          next_state = Enum.at(state_sequence, index)
          transition_prompt_one_step(acc_prompt, next_state)
        end)

      true ->
        prompt
    end
  end

  defp transition_prompt_one_step(prompt, target_state) do
    case target_state do
      :processing ->
        {:ok, prompt} = Batching.prompt_begin_processing(prompt)
        prompt

      :processed ->
        {:ok, prompt} = Batching.prompt_complete_processing(prompt)
        prompt

      :delivering ->
        {:ok, prompt} = Batching.prompt_begin_delivery(prompt)
        prompt

      :delivered ->
        {:ok, prompt} = Batching.prompt_complete_delivery(prompt)
        prompt

      _ ->
        prompt
    end
  end
end
