defmodule Batcher.Batching.Handlers.PayloadBuilder do
  @moduledoc """
  Builds request payloads for different endpoint types.

  Converts validated request data into JSON-compatible maps that will be
  stored in the request_payload field and later used to generate JSONL
  files for batch upload to the LLM provider.

  Handles all three endpoint types:
  - /v1/responses (chat completions)
  - /v1/embeddings (text embeddings)
  - /v1/moderations (content moderation)
  """

  @doc """
  Builds a payload for the /v1/responses endpoint (chat completions).

  Takes all fields from the request body except `delivery` and `tag`.
  Renames `endpoint` to `url` as required by the LLM API.
  The `custom_id` is preserved as it's part of the LLM API payload.
  Normalizes the `input` field to ensure proper formatting for the LLM API.

  ## Examples

      iex> build_responses_payload(%{
      ...>   "model" => "gpt-4o",
      ...>   "input" => [%{"role" => "user", "content" => "Hello!"}],
      ...>   "temperature" => 0.7,
      ...>   "endpoint" => "/v1/responses",
      ...>   "delivery" => %{"type" => "webhook"},
      ...>   "custom_id" => "123"
      ...> })
      %{"model" => "gpt-4o", "input" => [%{"role" => "user", "content" => "Hello!"}], "temperature" => 0.7, "url" => "/v1/responses", "custom_id" => "123"}
  """
  def build_responses_payload(body) when is_map(body) do
    body
    |> normalize_keys()
    |> Map.drop(["delivery", "tag"])
    |> rename_key("endpoint", "url")
    |> Map.put("method", "POST")
    |> Map.update("input", nil, &normalize_input/1)
  end

  @doc """
  Builds a payload for the /v1/embeddings endpoint.

  Takes all fields from the request body except `delivery` and `tag`.
  Renames `endpoint` to `url` as required by the LLM API.
  The `custom_id` is preserved as it's part of the LLM API payload.
  Normalizes the `input` field to ensure proper formatting for the LLM API.

  ## Examples

      iex> build_embeddings_payload(%{
      ...>   "model" => "text-embedding-3-large",
      ...>   "input" => "Sample text",
      ...>   "dimensions" => 1536,
      ...>   "endpoint" => "/v1/embeddings",
      ...>   "custom_id" => "123"
      ...> })
      %{"model" => "text-embedding-3-large", "input" => "Sample text", "dimensions" => 1536, "url" => "/v1/embeddings", "custom_id" => "123"}
  """
  def build_embeddings_payload(body) when is_map(body) do
    body
    |> normalize_keys()
    |> Map.drop(["delivery", "tag"])
    |> rename_key("endpoint", "url")
    |> Map.put("method", "POST")
    |> Map.update("input", nil, &normalize_input/1)
  end

  @doc """
  Builds a payload for the /v1/moderations endpoint.

  Takes all fields from the request body except `delivery` and `tag`.
  Renames `endpoint` to `url` as required by the LLM API.
  The `custom_id` is preserved as it's part of the LLM API payload.
  Normalizes the `input` field to ensure proper formatting for the LLM API.

  ## Examples

      iex> build_moderation_payload(%{
      ...>   "model" => "omni-moderation-latest",
      ...>   "input" => "Content to moderate",
      ...>   "endpoint" => "/v1/moderations",
      ...>   "custom_id" => "123"
      ...> })
      %{"model" => "omni-moderation-latest", "input" => "Content to moderate", "url" => "/v1/moderations", "custom_id" => "123"}
  """
  def build_moderation_payload(body) when is_map(body) do
    body
    |> normalize_keys()
    |> Map.drop(["delivery", "tag"])
    |> rename_key("endpoint", "url")
    |> Map.put("method", "POST")
    |> Map.update("input", nil, &normalize_input/1)
  end

  @doc """
  Normalizes input to a consistent format for JSON encoding.

  Handles:
  - Plain strings (pass through)
  - Arrays of strings (pass through)
  - Arrays of message maps with "role" and "content" (pass through)
  - Arrays of message structs (convert to maps)
  """
  def normalize_input(input) when is_binary(input), do: input

  def normalize_input(input) when is_list(input) do
    # Handle array of strings or array of message objects
    Enum.map(input, fn
      # Message struct (from Ash embedded resource) - convert to map
      %{__struct__: Batcher.Batching.Resources.Message, role: role, content: content} ->
        %{"role" => Atom.to_string(role), "content" => content}

      # Already a map with string keys (from HTTP JSON)
      %{"role" => role, "content" => content} when is_binary(role) ->
        %{"role" => role, "content" => content}

      # Map with atom keys (from tests or direct API calls)
      %{role: role, content: content} ->
        %{"role" => normalize_role(role), "content" => content}

      # Plain string (for embeddings/moderation)
      string when is_binary(string) ->
        string

      # Pass through anything else
      other ->
        other
    end)
  end

  def normalize_input(input), do: input

  # Helper to normalize map keys to strings
  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # Helper to rename a key in a map
  defp rename_key(map, old_key, new_key) do
    case Map.pop(map, old_key) do
      {nil, map} -> map
      {value, map} -> Map.put(map, new_key, value)
    end
  end

  # Helper to normalize role - handles both atoms and strings
  defp normalize_role(role) when is_atom(role), do: Atom.to_string(role)
  defp normalize_role(role) when is_binary(role), do: role
end
