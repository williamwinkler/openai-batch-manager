defmodule Batcher.Batching.Resources.TextFormat do
  @moduledoc """
  Embedded resource for the `text` parameter of /v1/responses endpoint.

  Configures the text response format, including structured outputs via JSON schema.
  """
  use Ash.Resource,
    domain: Batcher.Batching,
    data_layer: :embedded

  validations do
    validate Batcher.Batching.Validations.ValidateTextFormat
  end

  attributes do
    attribute :format, :map do
      description "Text format configuration"
      allow_nil? false
      public? true
    end
  end
end
