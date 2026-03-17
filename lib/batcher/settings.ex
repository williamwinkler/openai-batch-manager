defmodule Batcher.Settings do
  @moduledoc """
  Domain API for rate-limit settings and model overrides.
  """
  use Ash.Domain,
    otp_app: :batcher

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

  @doc """
  Returns the singleton rate-limit settings, creating defaults if needed.
  """
  @spec get_rate_limit_settings!() :: Batcher.Settings.Setting.t()
  def get_rate_limit_settings! do
    ensure_rate_limit_settings!()
  end

  @doc """
  Ensures the singleton settings record exists and returns it.
  """
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

  @doc """
  Upserts a model token-limit override on the singleton settings record.
  """
  @spec upsert_model_override!(String.t(), pos_integer()) :: Batcher.Settings.Setting.t()
  def upsert_model_override!(model_prefix, token_limit)
      when is_binary(model_prefix) and is_integer(token_limit) do
    settings = ensure_rate_limit_settings!()
    set_model_override!(settings, model_prefix, token_limit)
  end

  @doc """
  Removes a model token-limit override from the singleton settings record.
  """
  @spec delete_model_override!(String.t()) :: Batcher.Settings.Setting.t()
  def delete_model_override!(model_prefix) when is_binary(model_prefix) do
    settings = ensure_rate_limit_settings!()
    remove_model_override!(settings, model_prefix)
  end

  @doc """
  Lists model token-limit overrides as sorted maps for UI/API consumers.
  """
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
    case fetch_rate_limit_settings() do
      {:ok, %Setting{} = settings} ->
        {:ok, settings}

      {:error, error} ->
        if not_found_error?(error) do
          {:ok, nil}
        else
          {:error, error}
        end
    end
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &not_found_error?/1)
  end

  defp not_found_error?(_), do: false
end
