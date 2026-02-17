defmodule Batcher.Settings.Changes.UpsertModelOverride do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    model_prefix =
      changeset
      |> Ash.Changeset.get_argument(:model_prefix)
      |> normalize_model_prefix()

    if model_prefix == "" do
      Ash.Changeset.add_error(changeset, field: :model_prefix, message: "cannot be blank")
    else
      token_limit = Ash.Changeset.get_argument(changeset, :token_limit)
      existing = Ash.Changeset.get_attribute(changeset, :model_token_overrides) || %{}
      updated = Map.put(existing, model_prefix, token_limit)

      Ash.Changeset.change_attribute(changeset, :model_token_overrides, updated)
    end
  end

  defp normalize_model_prefix(model_prefix) do
    model_prefix
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end
