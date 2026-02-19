defmodule BatcherWeb.SettingsLiveTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Settings

  defmodule DataResetOkMock do
    def erase_all, do: :ok
  end

  setup do
    original_data_reset_module = Application.get_env(:batcher, :data_reset_module)

    on_exit(fn ->
      if is_nil(original_data_reset_module) do
        Application.delete_env(:batcher, :data_reset_module)
      else
        Application.put_env(:batcher, :data_reset_module, original_data_reset_module)
      end
    end)

    :ok
  end

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
      assert html =~ ~s|href="/settings/database/download"|
      assert html =~ "Danger Zone"
      assert html =~ "Download DB Snapshot"
      assert html =~ "Erase DB"
      assert html =~ ~s|phx-click="erase_db"|
    end

    test "creates override from form submission", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-override-form")
      |> render_submit(%{
        "override" => %{"model_prefix" => "gpt-4o-mini", "token_limit" => "123456"}
      })

      wait_for(fn -> render(view) =~ "Override saved" end)
      html = render(view)
      assert html =~ "Override saved"
      assert html =~ "gpt-4o-mini"
      assert html =~ "123,456 (123K)"

      assert Settings.list_model_overrides!() == [
               %{model_prefix: "gpt-4o-mini", token_limit: 123_456}
             ]
    end

    test "shows save override loading state while pending", %{conn: conn} do
      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 200)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-override-form")
      |> render_submit(%{
        "override" => %{"model_prefix" => "gpt-4o-mini", "token_limit" => "123456"}
      })

      assert has_element?(view, "button#save-override[disabled]", "Saving...")
      :timer.sleep(300)
      refute render(view) =~ "Saving..."
    end

    test "accepts queue token cap with thousands separators", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-override-form")
      |> render_submit(%{
        "override" => %{"model_prefix" => "gpt-4o-mini", "token_limit" => "1,234,567"}
      })

      wait_for(fn ->
        Settings.list_model_overrides!() == [
          %{model_prefix: "gpt-4o-mini", token_limit: 1_234_567}
        ]
      end)

      assert Settings.list_model_overrides!() == [
               %{model_prefix: "gpt-4o-mini", token_limit: 1_234_567}
             ]
    end

    test "deletes existing override from table action", %{conn: conn} do
      _ = Settings.upsert_model_override!("gpt-4o-mini", 123_456)
      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 200)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("button#delete-override-gpt-4o-mini")
      |> render_click()

      assert has_element?(view, "button#delete-override-gpt-4o-mini[disabled]", "Resetting...")
      :timer.sleep(300)
      html = render(view)
      assert html =~ "Override removed"
      assert html =~ "No model-specific overrides configured."
      assert Settings.list_model_overrides!() == []
    end

    test "shows validation feedback for invalid inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-override-form")
      |> render_submit(%{"override" => %{"model_prefix" => "   ", "token_limit" => "0"}})

      html = render(view)
      assert html =~ "Please fix the form errors"
    end

    test "erases database via phx-click event", %{conn: conn} do
      Application.put_env(:batcher, :data_reset_module, DataResetOkMock)
      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 200)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("button[phx-click='erase_db']")
      |> render_click()

      assert has_element?(view, "button#erase-db[disabled]", "Erasing...")
      :timer.sleep(300)
      html = render(view)
      assert html =~ "Database erased successfully"
    end
  end

  defp wait_for(fun, attempts \\ 40, sleep_ms \\ 20)

  defp wait_for(fun, attempts, _sleep_ms) when attempts <= 0 do
    assert fun.()
  end

  defp wait_for(fun, attempts, sleep_ms) do
    if fun.() do
      :ok
    else
      Process.sleep(sleep_ms)
      wait_for(fun, attempts - 1, sleep_ms)
    end
  end
end
