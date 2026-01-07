defmodule Batcher.Batching.Utils do
  @moduledoc """
  Utility functions for the Batching domain.
  """

  @doc """
  Extracts the subject ID from an Ash action input.

  This handles both direct action calls (where the subject is available) and
  Oban-triggered actions (where the ID is in the params).

  ## Examples

      # Direct call (e.g., in tests)
      iex> extract_subject_id(%{subject: %{id: "abc-123"}})
      "abc-123"

      # Oban-triggered call
      iex> extract_subject_id(%{params: %{"primary_key" => %{"id" => "abc-123"}}})
      "abc-123"
  """
  @spec extract_subject_id(map()) :: any()
  def extract_subject_id(input) do
    case Map.fetch(input, :subject) do
      {:ok, %{id: id}} -> id
      _ -> get_in(input.params, ["primary_key", "id"])
    end
  end
end
