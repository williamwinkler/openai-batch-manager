defmodule Batcher.Batching.Types.OpenaiBatchEndpoints do
  @moduledoc """
  OpenAI batch endpoints enum type.
  """
  use Ash.Type.Enum,
    values: [
    "/v1/responses",
    "/v1/chat/completions",
    "/v1/completions",
    "/v1/embeddings",
    "/v1/moderations",
  ]
end
