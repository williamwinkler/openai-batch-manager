defmodule BatcherWeb.SettingsLiveTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Settings

  describe "settings page" do
    test "renders page and navigation link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Settings"
      assert html =~ "Override Queue Token Cap"
      assert html =~ "Current Overrides"
      assert html =~ "Model"
      assert html =~ ~s|phx-hook="ModelTokenLimitPlaceholder"|
      assert html =~ ~s|data-model-default-limits=|
      assert html =~ ~s|list="model-suggestions"|
      assert html =~ ~s|<datalist id="model-suggestions">|
      assert html =~ ~s|value="gpt-4o-mini"|
      assert html =~ ~s|href="/settings"|
      assert html =~ "https://platform.openai.com/settings/organization/limits"
    end

    test "creates override from form submission", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("form")
      |> render_submit(%{
        "override" => %{"model_prefix" => "gpt-4o-mini", "token_limit" => "123456"}
      })

      html = render(view)
      assert html =~ "Override saved"
      assert html =~ "gpt-4o-mini"
      assert html =~ "123,456 (123K)"

      assert Settings.list_model_overrides!() == [
               %{model_prefix: "gpt-4o-mini", token_limit: 123_456}
             ]
    end

    test "accepts queue token cap with thousands separators", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("form")
      |> render_submit(%{
        "override" => %{"model_prefix" => "gpt-4o-mini", "token_limit" => "1,234,567"}
      })

      assert Settings.list_model_overrides!() == [
               %{model_prefix: "gpt-4o-mini", token_limit: 1_234_567}
             ]
    end

    test "deletes existing override from table action", %{conn: conn} do
      _ = Settings.upsert_model_override!("gpt-4o-mini", 123_456)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("button[phx-click='delete_override']")
      |> render_click()

      html = render(view)
      assert html =~ "Override removed"
      assert html =~ "No model-specific overrides configured."
      assert Settings.list_model_overrides!() == []
    end

    test "shows validation feedback for invalid inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("form")
      |> render_submit(%{"override" => %{"model_prefix" => "   ", "token_limit" => "0"}})

      html = render(view)
      assert html =~ "Please fix the form errors"
    end
  end
end
