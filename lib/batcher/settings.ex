defmodule Batcher.Settings do
  use Ash.Domain,
    otp_app: :batcher

  require Ash.Query

  alias Batcher.Settings.Setting

  resources do
    resource Batcher.Settings.Setting do
      define :fetch_rate_limit_settings, action: :singleton
      define :create_rate_limit_settings, action: :create_singleton

      define :set_model_override,
        action: :upsert_model_override,
        args: [:model_prefix, :token_limit]

      define :remove_model_override, action: :delete_model_override, args: [:model_prefix]
    end
  end

  @settings_name "openai_rate_limits"

  @spec get_rate_limit_settings!() :: Batcher.Settings.Setting.t()
  def get_rate_limit_settings! do
    ensure_rate_limit_settings!()
  end

  @spec ensure_rate_limit_settings!() :: Batcher.Settings.Setting.t()
  def ensure_rate_limit_settings! do
    case read_singleton() do
      {:ok, %Setting{} = settings} ->
        settings

      {:ok, nil} ->
        create_default_settings!()

      {:error, error} ->
        raise error
    end
  end

  @spec upsert_model_override!(String.t(), pos_integer()) :: Batcher.Settings.Setting.t()
  def upsert_model_override!(model_prefix, token_limit)
      when is_binary(model_prefix) and is_integer(token_limit) do
    ensure_rate_limit_settings!()
    |> Ash.Changeset.for_update(:upsert_model_override, %{
      model_prefix: model_prefix,
      token_limit: token_limit
    })
    |> Ash.update!()
  end

  @spec delete_model_override!(String.t()) :: Batcher.Settings.Setting.t()
  def delete_model_override!(model_prefix) when is_binary(model_prefix) do
    ensure_rate_limit_settings!()
    |> Ash.Changeset.for_update(:delete_model_override, %{model_prefix: model_prefix})
    |> Ash.update!()
  end

  @spec list_model_overrides!() :: list(%{model_prefix: String.t(), token_limit: pos_integer()})
  def list_model_overrides! do
    ensure_rate_limit_settings!()
    |> Map.get(:model_token_overrides, %{})
    |> Enum.map(fn {model_prefix, token_limit} ->
      %{model_prefix: model_prefix, token_limit: token_limit}
    end)
    |> Enum.sort_by(&String.downcase(&1.model_prefix))
  end

  defp create_default_settings! do
    create_rate_limit_settings!(%{
      name: @settings_name,
      model_token_overrides: %{}
    })
  rescue
    error ->
      case read_singleton() do
        {:ok, %Setting{} = settings} -> settings
        {:error, _} -> raise error
        {:ok, nil} -> raise error
      end
  end

  defp read_singleton do
    Setting
    |> Ash.Query.for_read(:singleton, %{})
    |> Ash.read_one()
  end
end
