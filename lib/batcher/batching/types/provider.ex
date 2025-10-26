defmodule Batcher.Batching.Types.Provider do
  use Ash.Type.Enum,
    values: [
      openai: [
        label: "OpenAI"
      ]
    ]
end
