defmodule Batcher.Models do
  @chat_models [
    "gpt-3.5-turbo",
    "gpt-4o",
    "gpt-4o-mini",
    "gpt-4.1",
    "gpt-4.1-mini",
    "gpt-4.1-nano",
    "gpt-5",
    "gpt-5-mini",
    "gpt-5-nano",
    "gpt-5.1",
    "gpt-5.2",
    "o3-mini",
    "o3",
    "o4-mini",
    "o4"
  ]

  @moderation_models [
    "omni-moderation-latest",
    "text-moderation-latest"
  ]

  @embedding_models [
    "text-embedding-3-small",
    "text-embedding-3-large",
    "text-embedding-ada-002"
  ]

  @doc """
  Returns a suitable model for the given URL.
  """
  def model("/v1/responses"), do: random_chat_model()
  def model("/v1/chat/completions"), do: random_chat_model()
  def model("/v1/completions"), do: random_chat_model()
  def model("/v1/moderations"), do: random_moderation_model()
  def model("/v1/embeddings"), do: random_embedding_model()

  # Private helpers
  defp random_chat_model, do: Enum.random(@chat_models)
  defp random_moderation_model, do: Enum.random(@moderation_models)
  defp random_embedding_model, do: Enum.random(@embedding_models)
end
