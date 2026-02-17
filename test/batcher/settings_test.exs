defmodule Batcher.SettingsTest do
  use Batcher.DataCase, async: false

  alias Batcher.Settings
  alias Batcher.Settings.Setting

  describe "singleton settings row" do
    test "ensure_rate_limit_settings!/0 creates row if missing and is idempotent" do
      settings_one = Settings.ensure_rate_limit_settings!()
      settings_two = Settings.ensure_rate_limit_settings!()

      assert settings_one.id == settings_two.id

      all = Ash.read!(Setting)
      assert length(all) == 1
    end
  end

  describe "model overrides" do
    test "upsert_model_override!/2 writes normalized model prefixes" do
      settings = Settings.upsert_model_override!(" GPT-4O-MINI ", 2_500_000)

      assert settings.model_token_overrides["gpt-4o-mini"] == 2_500_000
    end

    test "delete_model_override!/1 removes override key" do
      _ = Settings.upsert_model_override!("gpt-4o-mini", 2_500_000)
      settings = Settings.delete_model_override!("gpt-4o-mini")

      refute Map.has_key?(settings.model_token_overrides, "gpt-4o-mini")
    end

    test "list_model_overrides!/0 returns sorted overrides" do
      _ = Settings.upsert_model_override!("gpt-4o-mini", 2_000_000)
      _ = Settings.upsert_model_override!("gpt-4o", 90_000)

      assert Settings.list_model_overrides!() == [
               %{model_prefix: "gpt-4o", token_limit: 90_000},
               %{model_prefix: "gpt-4o-mini", token_limit: 2_000_000}
             ]
    end

    test "rejects blank model_prefix values" do
      assert_raise Ash.Error.Invalid, fn ->
        Settings.upsert_model_override!("   ", 123)
      end
    end

    test "rejects non-positive token_limit values" do
      assert_raise Ash.Error.Invalid, fn ->
        Settings.upsert_model_override!("gpt-4o-mini", 0)
      end
    end
  end
end
