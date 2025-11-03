defmodule Batcher.Batching.Types.EmbeddingsInput do
  @moduledoc """
  Union type for the input field of /v1/embeddings endpoint.

  Can be either:
  - A single string to embed
  - An array of strings to embed in batch
  """

  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        text: [
          type: :string,
          constraints: [min_length: 1]
        ],
        texts: [
          type: {:array, :string}
        ]
      ]
    ]
end
