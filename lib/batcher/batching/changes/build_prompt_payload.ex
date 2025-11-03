defmodule Batcher.Batching.Changes.BuildPromptPayload do
  @moduledoc """
  Builds the request_payload for the prompt based on the endpoint type.

  Extracts all fields from the request_body argument and creates a JSON-compatible
  map that will be stored in the request_payload attribute. This payload is later
  used to generate the JSONL file for batch upload to the LLM provider.

  Handles all three endpoint types:
  - /v1/responses
  - /v1/embeddings
  - /v1/moderations
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    request_body = Ash.Changeset.get_argument(changeset, :request_body)

    case request_body do
      nil ->
        changeset

      %{__struct__: struct_module} = body ->
        payload =
          case struct_module do
            Batcher.Batching.Resources.ResponsesRequestBody ->
              build_responses_payload(body)

            Batcher.Batching.Resources.EmbeddingsRequestBody ->
              build_embeddings_payload(body)

            Batcher.Batching.Resources.ModerationRequestBody ->
              build_moderation_payload(body)

            _ ->
              %{}
          end

        Ash.Changeset.force_change_attribute(changeset, :request_payload, payload)
    end
  end

  defp build_responses_payload(body) do
    payload = %{
      "model" => body.model,
      "input" => normalize_input(body.input)
    }

    # Add optional fields
    payload
    |> add_if_present("instructions", body.instructions)
    |> add_if_present("temperature", body.temperature)
    |> add_if_present("max_output_tokens", body.max_output_tokens)
    |> add_if_present("top_p", body.top_p)
    |> add_if_present("store", body.store)
  end

  defp build_embeddings_payload(body) do
    payload = %{
      "model" => body.model,
      "input" => normalize_input(body.input)
    }

    # Add optional fields
    payload
    |> add_if_present("dimensions", body.dimensions)
    |> add_if_present("encoding_format", body.encoding_format)
  end

  defp build_moderation_payload(body) do
    %{
      "model" => body.model,
      "input" => normalize_input(body.input)
    }
  end

  defp normalize_input(input) when is_binary(input), do: input

  defp normalize_input(input) when is_list(input) do
    # Handle array of strings or array of Message structs
    Enum.map(input, fn
      %{__struct__: Batcher.Batching.Resources.Message, role: role, content: content} ->
        %{"role" => role, "content" => content}

      string when is_binary(string) ->
        string

      other ->
        other
    end)
  end

  defp normalize_input(input), do: input

  defp add_if_present(payload, _key, nil), do: payload
  defp add_if_present(payload, key, value), do: Map.put(payload, key, value)
end
