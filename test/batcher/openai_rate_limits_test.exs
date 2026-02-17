defmodule Batcher.OpenaiRateLimitsTest do
  use Batcher.DataCase, async: false

  alias Batcher.OpenaiRateLimits
  alias Batcher.Settings

  test "override limit beats tier 1 default" do
    _ = Settings.upsert_model_override!("gpt-4o-mini", 3_000_000)

    assert {:ok, %{limit: 3_000_000, source: :override, matched_model: "gpt-4o-mini"}} =
             OpenaiRateLimits.get_batch_limit_tokens("gpt-4o-mini-2024-07-18")
  end

  test "longest matching prefix wins for overrides" do
    _ = Settings.upsert_model_override!("gpt-4o", 100_000)
    _ = Settings.upsert_model_override!("gpt-4o-mini", 2_000_000)

    assert {:ok, %{limit: 2_000_000, source: :override, matched_model: "gpt-4o-mini"}} =
             OpenaiRateLimits.get_batch_limit_tokens("gpt-4o-mini-2024-07-18")
  end

  test "falls back to tier 1 defaults when no override exists" do
    assert {:ok, %{limit: 90_000, source: :tier_1_default, matched_model: nil}} =
             OpenaiRateLimits.get_batch_limit_tokens("gpt-4o-2024-08-06")
  end

  test "more specific prefixes override general family defaults" do
    assert {:ok, %{limit: 200_000, source: :tier_1_default, matched_model: nil}} =
             OpenaiRateLimits.get_batch_limit_tokens("gpt-3.5-turbo-instruct-0914")

    assert {:ok, %{limit: 900_000, source: :tier_1_default, matched_model: nil}} =
             OpenaiRateLimits.get_batch_limit_tokens("gpt-5.1-2025-11-13")

    assert {:ok, %{limit: 6_000, source: :tier_1_default, matched_model: nil}} =
             OpenaiRateLimits.get_batch_limit_tokens("gpt-4o-mini-search-preview-2025-03-11")
  end

  test "uses unknown fallback when model has no override and no known default" do
    fallback_limit =
      Application.get_env(:batcher, :capacity_control, [])
      |> Keyword.get(:default_unknown_model_batch_limit_tokens, 250_000)

    assert {:ok, %{limit: ^fallback_limit, source: :fallback, matched_model: nil}} =
             OpenaiRateLimits.get_batch_limit_tokens("my-unknown-model")
  end
end
