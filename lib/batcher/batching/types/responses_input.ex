defmodule Batcher.Batching.Types.ResponsesInput do
  @moduledoc """
  Union type for the input field of /v1/responses endpoint.

  Can be either:
  - A plain text string
  - An array of Message objects (conversation format)
  """

  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        text: [
          type: :string,
          constraints: [min_length: 1]
        ],
        messages: [
          type: {:array, Batcher.Batching.Resources.Message}
        ]
      ]
    ]
end
