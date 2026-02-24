defmodule Batcher.Settings.Setting do
  @moduledoc """
  Ash resource storing singleton settings and model overrides.
  """
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Settings,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "settings"
    repo Batcher.Repo
  end

  actions do
    defaults [:read]

    create :create_singleton do
      accept [:name, :model_token_overrides]
    end

    read :singleton do
      get? true
      filter expr(name == "openai_rate_limits")
    end

    update :upsert_model_override do
      require_atomic? false
      argument :model_prefix, :string, allow_nil?: false
      argument :token_limit, :integer, allow_nil?: false
      validate string_length(:model_prefix, min: 1)
      validate compare(:token_limit, greater_than: 0)
      change Batcher.Settings.Changes.UpsertModelOverride
    end

    update :delete_model_override do
      require_atomic? false
      argument :model_prefix, :string, allow_nil?: false
      validate string_length(:model_prefix, min: 1)
      change Batcher.Settings.Changes.DeleteModelOverride
    end
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      allow_nil? false
      default "openai_rate_limits"
      public? true
    end

    attribute :model_token_overrides, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_settings_name, [:name]
  end
end
