defmodule Batcher.Batching.Types.ModerationInput do
  @moduledoc """
  Union type for the input field of /v1/moderations endpoint.

  Can be either:
  - A single string to moderate
  - An array of strings to moderate in batch
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
