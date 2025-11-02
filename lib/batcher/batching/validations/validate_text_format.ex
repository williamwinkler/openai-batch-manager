defmodule Batcher.Batching.Validations.ValidateTextFormat do
  @moduledoc """
  Validates the text format configuration for structured outputs.

  Ensures:
  - format.type is one of: text, json_object, json_schema
  - When type is json_schema, validates the schema structure
  - Uses ex_json_schema to validate the JSON schema itself
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :format) do
      nil -> :ok
      format when is_map(format) -> validate_format(format)
      _ -> {:error, field: :format, message: "format must be a map"}
    end
  end

  defp validate_format(%{"type" => type} = format)
       when type in ["text", "json_object", "json_schema"] do
    if type == "json_schema" do
      validate_json_schema(format)
    else
      :ok
    end
  end

  defp validate_format(_) do
    {:error,
     field: :format, message: "format.type must be one of: text, json_object, json_schema"}
  end

  defp validate_json_schema(%{"json_schema" => schema}) when is_map(schema) do
    # Validate required fields
    cond do
      not Map.has_key?(schema, "name") ->
        {:error, field: :format, message: "json_schema.name is required"}

      not Map.has_key?(schema, "schema") ->
        {:error, field: :format, message: "json_schema.schema is required"}

      true ->
        # Validate the schema itself using ex_json_schema
        case ExJsonSchema.Schema.resolve(schema["schema"]) do
          {:ok, _} ->
            :ok

          {:error, errors} ->
            {:error, field: :format, message: "Invalid JSON schema: #{inspect(errors)}"}
        end
    end
  end

  defp validate_json_schema(_) do
    {:error, field: :format, message: "json_schema must be provided when type is json_schema"}
  end
end
