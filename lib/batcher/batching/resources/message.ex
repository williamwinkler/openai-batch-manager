defmodule Batcher.Batching.Resources.Message do
  @moduledoc """
  Embedded resource representing a message in a conversation.

  Used for the `input` field of /v1/responses when providing a conversation
  instead of a simple string.
  """
  use Ash.Resource,
    domain: Batcher.Batching,
    data_layer: :embedded

  attributes do
    attribute :role, :atom do
      description "Message role: developer, user, or assistant"
      allow_nil? false
      constraints one_of: [:developer, :user, :assistant]
      public? true
    end

    attribute :content, :string do
      description "Message content"
      allow_nil? false
      public? true
    end
  end
end
