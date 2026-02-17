defmodule Batcher.OpenaiRateLimits do
  @moduledoc """
  Provides per-model batch queue token limits using built-in Tier 1 defaults.
  """
  use GenServer
  require Logger

  @table __MODULE__
  @tier_1_batch_limits [
    {"gpt-5.2-chat-latest", 900_000},
    {"gpt-5.2-codex", 900_000},
    {"gpt-5.2-pro", 900_000},
    {"gpt-5.2", 900_000},
    {"gpt-5.1-chat-latest", 900_000},
    {"gpt-5.1-codex-max", 900_000},
    {"gpt-5.1-codex-mini", 2_000_000},
    {"gpt-5.1-codex", 900_000},
    {"gpt-5.1", 900_000},
    {"gpt-5-search-api", 6_000},
    {"gpt-4o-mini", 2_000_000},
    {"gpt-4o-mini-search-preview", 6_000},
    {"gpt-4o-mini-transcribe-2025-12-15", 250_000},
    {"gpt-4o-mini-transcribe-2025-03-20", 250_000},
    {"gpt-4o-mini-transcribe", 50_000},
    {"gpt-4o-mini-tts-2025-12-15", 250_000},
    {"gpt-4o-mini-tts-2025-03-20", 250_000},
    {"gpt-4o-mini-tts", 50_000},
    {"gpt-4.1-mini-long-context", 4_000_000},
    {"gpt-4.1-mini", 2_000_000},
    {"gpt-4.1-nano-long-context", 4_000_000},
    {"gpt-4.1-nano", 2_000_000},
    {"gpt-4.1-long-context", 2_000_000},
    {"gpt-4.1", 900_000},
    {"gpt-4o-search-preview", 6_000},
    {"gpt-4o-transcribe-diarize", 250_000},
    {"gpt-4o-transcribe", 10_000},
    {"gpt-4o-audio-preview-2025-06-03", 250_000},
    {"gpt-4o", 90_000},
    {"gpt-4-turbo", 90_000},
    {"gpt-4", 100_000},
    {"gpt-3.5-turbo-instruct", 200_000},
    {"gpt-3.5-turbo", 2_000_000},
    {"gpt-audio-mini", 250_000},
    {"gpt-audio", 250_000},
    {"o4-mini", 2_000_000},
    {"o4-mini-deep-research-2025-06-26", 250_000},
    {"o4-mini-deep-research", 200_000},
    {"o3-mini", 2_000_000},
    {"o3", 90_000},
    {"o1-pro", 90_000},
    {"o1", 90_000},
    {"text-embedding-3-large", 3_000_000},
    {"text-embedding-3-small", 3_000_000},
    {"text-embedding-ada-002", 3_000_000},
    {"omni-moderation-2024-09-26", 1_000_000},
    {"omni-moderation-latest", 1_000_000},
    {"gpt-5-mini", 5_000_000},
    {"gpt-5-nano", 2_000_000},
    {"gpt-5-pro", 90_000},
    {"gpt-5-chat-latest", 900_000},
    {"gpt-5-codex", 900_000},
    {"gpt-5", 1_500_000}
  ]

  @type limit_source :: :override | :tier_1_default | :fallback

  @doc """
  Starts the limits cache server.

  Initializes the ETS table for limit lookups.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the per-model batch queue token limit used for admission checks.

  Returns the configured limit in this order:
  1. User-defined model override (`source: :override`)
  2. Tier 1 default per-model limit (`source: :tier_1_default`)
  3. Conservative unknown-model fallback (`source: :fallback`)

  ## Examples

      iex> {:ok, result} = Batcher.OpenaiRateLimits.get_batch_limit_tokens("doctest-unknown-model")
      iex> result.source == :fallback
      true
      iex> is_integer(result.limit) and result.limit > 0
      true
  """
  @spec get_batch_limit_tokens(String.t()) ::
          {:ok, %{limit: pos_integer(), source: limit_source(), matched_model: String.t() | nil}}
  def get_batch_limit_tokens(model) when is_binary(model) do
    with :error <- override_for_model(model),
         nil <- tier_1_default_limit_for_model(model) do
      {:ok, %{limit: fallback_limit(model), source: :fallback, matched_model: nil}}
    else
      {:ok, data} ->
        {:ok, data}

      limit when is_integer(limit) ->
        {:ok, %{limit: limit, source: :tier_1_default, matched_model: nil}}
    end
  rescue
    ArgumentError ->
      {:ok, %{limit: fallback_limit(model), source: :fallback, matched_model: nil}}
  end

  @doc """
  Returns known Tier 1 model keys used for queue token limits.
  """
  @spec model_prefix_suggestions() :: [String.t()]
  def model_prefix_suggestions do
    Enum.map(@tier_1_batch_limits, fn {prefix, _limit} -> prefix end)
  end

  @doc """
  Returns known Tier 1 model keys and their default queue token caps.
  """
  @spec model_prefix_default_limits() :: %{required(String.t()) => pos_integer()}
  def model_prefix_default_limits do
    Map.new(@tier_1_batch_limits)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  defp maybe_log_missing_model(model) do
    key = {:missing_model_limit_warned, model}

    if :persistent_term.get(key, false) == false do
      Logger.warning(
        "No OpenAI rate-limit entry for model #{inspect(model)}. Using fallback limit."
      )

      :persistent_term.put(key, true)
    end
  end

  defp override_for_model(model) when is_binary(model) do
    downcased_model = String.downcase(model)

    case Batcher.Settings.list_model_overrides!() do
      [] ->
        :error

      overrides ->
        overrides
        |> Enum.filter(fn %{model_prefix: model_prefix} ->
          String.starts_with?(downcased_model, model_prefix)
        end)
        |> Enum.max_by(fn %{model_prefix: model_prefix} -> String.length(model_prefix) end, fn ->
          nil
        end)
        |> case do
          nil ->
            :error

          %{model_prefix: model_prefix, token_limit: token_limit} ->
            {:ok, %{limit: token_limit, source: :override, matched_model: model_prefix}}
        end
    end
  rescue
    _ ->
      :error
  end

  # Tier 1 default batch queue limits per model from OpenAI's published rate limits.
  defp tier_1_default_limit_for_model(model) when is_binary(model) do
    downcased = String.downcase(model)

    @tier_1_batch_limits
    |> Enum.filter(fn {prefix, _limit} -> String.starts_with?(downcased, prefix) end)
    |> Enum.max_by(fn {prefix, _limit} -> String.length(prefix) end, fn -> nil end)
    |> case do
      {_, limit} -> limit
      nil -> nil
    end
  end

  defp fallback_limit(model) when is_binary(model) do
    maybe_log_missing_model(model)

    Application.get_env(:batcher, :capacity_control, [])
    |> Keyword.get(:default_unknown_model_batch_limit_tokens, 250_000)
  end
end
