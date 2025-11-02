defmodule Batcher.Batching.Types.ResponsesInputType do
  @moduledoc """
  Custom type for the `input` parameter of the /v1/responses endpoint.

  Can be:
  - A string: "Tell me a story"
  - An array of Message maps: [%{role: :user, content: "Hello"}]
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
