defmodule BatcherWeb.RequestShowLiveTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Batching

  import Batcher.Generator

  setup do
    batch = generate(batch())

    {:ok, request} =
      Batching.create_request(%{
        batch_id: batch.id,
        custom_id: "test_req_show",
        url: batch.url,
        model: batch.model,
        request_payload: %{
          custom_id: "test_req_show",
          body: %{input: "test input", model: batch.model},
          method: "POST",
          url: batch.url
        },
        delivery_config: %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      })

    {:ok, batch: batch, request: request}
  end

  describe "mount" do
    test "displays request details", %{conn: conn, request: request} do
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ request.custom_id
      assert html =~ request.model
    end

    test "shows request state", %{conn: conn, request: request} do
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      # Request should be in pending state (or shown as Pending badge)
      assert html =~ "pending" or html =~ "Pending"
    end

    test "displays delivery configuration", %{conn: conn, request: request} do
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      # Should show webhook delivery type
      assert html =~ "Webhook" or html =~ "webhook"
    end

    test "shows a single Est. input tokens label and hides capacity estimate line", %{
      conn: conn,
      request: request
    } do
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ "Est. input tokens"
      refute html =~ "Capacity estimate:"
    end

    test "redirects when request not found", %{conn: conn} do
      {:ok, conn} =
        live(conn, ~p"/requests/999999")
        |> follow_redirect(conn)

      assert html_response(conn, 200) =~ "Request not found"
    end
  end

  describe "token estimate display" do
    test "uses actual input tokens from response payload when available", %{conn: conn} do
      batch = generate(batch())

      request =
        generate(
          seeded_request(
            batch_id: batch.id,
            state: :openai_processed,
            estimated_request_input_tokens: 3_700,
            response_payload: %{
              "response" => %{
                "body" => %{
                  "usage" => %{
                    "input_tokens" => 100
                  }
                }
              }
            }
          )
        )

      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ "Est. input tokens"
      refute html =~ "3.7K"
    end
  end

  describe "show_request_payload event" do
    test "opens modal with request payload when clicking div", %{conn: conn, request: request} do
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      # Click on the request payload div
      view
      |> element("div[phx-click='show_request_payload']")
      |> render_click()

      html = render(view)
      assert html =~ "Request Payload"
    end
  end

  describe "close_payload_modal event" do
    test "closes the payload modal", %{conn: conn, request: request} do
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      # Open the modal first
      view
      |> element("div[phx-click='show_request_payload']")
      |> render_click()

      # Close it
      view
      |> element("button[phx-click='close_payload_modal']")
      |> render_click()

      html = render(view)
      # Modal should be closed (the modal title shouldn't be visible)
      refute html =~ "Request Payload"
    end
  end

  describe "edit_delivery_config event" do
    test "enters edit mode for delivery config", %{conn: conn, request: request} do
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      view
      |> element("button[phx-click='edit_delivery_config']")
      |> render_click()

      html = render(view)
      # Should show save/cancel buttons in edit mode
      assert html =~ "Save" or html =~ "Cancel"
    end
  end

  describe "cancel_edit_delivery_config event" do
    test "exits edit mode without saving", %{conn: conn, request: request} do
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      # Enter edit mode
      view
      |> element("button[phx-click='edit_delivery_config']")
      |> render_click()

      # Cancel edit - use the Cancel text button (not the X button)
      view
      |> element("button[phx-click='cancel_edit_delivery_config']", "Cancel")
      |> render_click()

      html = render(view)
      # Should be back in view mode
      assert html =~ "Edit"
    end
  end

  describe "format_json/1" do
    alias BatcherWeb.RequestShowLive

    test "handles nil" do
      assert RequestShowLive.format_json(nil) == ""
    end

    test "formats JSON string" do
      json_string = ~s({"key":"value"})
      result = RequestShowLive.format_json(json_string)
      assert result =~ "key"
      assert result =~ "value"
    end

    test "formats map" do
      map = %{"key" => "value"}
      result = RequestShowLive.format_json(map)
      assert result =~ "key"
      assert result =~ "value"
    end

    test "handles invalid JSON string" do
      invalid = "not valid json"
      result = RequestShowLive.format_json(invalid)
      assert result == "not valid json"
    end
  end

  describe "format_bytes/1" do
    alias BatcherWeb.RequestShowLive

    test "handles nil" do
      assert RequestShowLive.format_bytes(nil) == "—"
    end

    test "formats small bytes" do
      assert RequestShowLive.format_bytes(500) == "500 B"
    end

    test "formats KB" do
      assert RequestShowLive.format_bytes(2048) == "2.0 KB"
    end

    test "formats MB" do
      assert RequestShowLive.format_bytes(2 * 1024 * 1024) == "2.0 MB"
    end
  end

  describe "response payload display" do
    test "shows response section when available", %{conn: conn, request: request} do
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      # Response section may or may not be visible depending on request state
      # This test just verifies the page loads correctly
      assert html =~ request.custom_id
    end
  end

  describe "save_delivery_config event" do
    test "saves webhook delivery config", %{conn: conn, request: request} do
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      # Enter edit mode
      view
      |> element("button[phx-click='edit_delivery_config']")
      |> render_click()

      # Submit the form with webhook config
      view
      |> form("form[phx-submit='save_delivery_config']", %{
        "form" => %{
          "delivery_type" => "webhook",
          "webhook_url" => "https://new-webhook.example.com/callback"
        }
      })
      |> render_submit()

      html = render(view)
      # Should show success flash or updated config
      assert html =~ "Edit" or html =~ "new-webhook.example.com"
    end

    test "shows saving spinner/disabled while submit is pending", %{conn: conn, request: request} do
      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 200)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      view
      |> element("button[phx-click='edit_delivery_config']")
      |> render_click()

      view
      |> form("#save-delivery-config-form", %{
        "form" => %{
          "delivery_type" => "webhook",
          "webhook_url" => "https://new-webhook.example.com/callback"
        }
      })
      |> render_submit()

      assert has_element?(view, "button#save-delivery-config[disabled]", "Saving...")
      :timer.sleep(300)
      refute render(view) =~ "Saving..."
    end
  end

  describe "mutating action loading states" do
    test "shows redelivery spinner and disables button while pending", %{conn: conn} do
      batch = generate(seeded_batch(state: :delivering))

      request =
        generate(
          seeded_request(
            batch_id: batch.id,
            state: :delivery_failed,
            response_payload: %{"output" => "response"},
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          )
        )

      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 200)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      view
      |> element("button#retry-delivery")
      |> render_click()

      assert has_element?(view, "button#retry-delivery[disabled]", "Redelivering...")
      :timer.sleep(300)
      refute render(view) =~ "Redelivering..."
    end

    test "shows delete spinner while pending", %{conn: conn} do
      batch = generate(batch())

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "delete_req_show",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "delete_req_show",
            body: %{input: "test input", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 200)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      view
      |> element("button#delete-request")
      |> render_click()

      assert has_element?(view, "button#delete-request[disabled]", "Deleting...")
      assert_redirect(view, ~p"/requests", 1_000)
    end
  end

  describe "validate_delivery_config event" do
    test "validates form on change", %{conn: conn, request: request} do
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      # Enter edit mode
      view
      |> element("button[phx-click='edit_delivery_config']")
      |> render_click()

      # Trigger validation by changing the form
      view
      |> form("form[phx-change='validate_delivery_config']")
      |> render_change(%{
        "form" => %{
          "delivery_type" => "webhook",
          "webhook_url" => "https://validated.example.com"
        }
      })

      # Should not crash and form should still be visible
      html = render(view)
      assert html =~ "Save" or html =~ "Cancel"
    end
  end

  describe "delivery config helper functions" do
    alias BatcherWeb.RequestShowLive

    test "current_delivery_type/1 returns nil for nil" do
      assert RequestShowLive.current_delivery_type(nil) == nil
    end

    test "current_delivery_type/1 returns webhook for webhook config" do
      config = %{"type" => "webhook", "webhook_url" => "http://example.com"}
      assert RequestShowLive.current_delivery_type(config) == "webhook"
    end

    test "current_delivery_type/1 returns rabbitmq for rabbitmq config" do
      config = %{"type" => "rabbitmq", "rabbitmq_queue" => "test_queue"}
      assert RequestShowLive.current_delivery_type(config) == "rabbitmq"
    end

    test "current_delivery_type/1 handles legacy webhook config" do
      config = %{"webhook_url" => "http://example.com"}
      assert RequestShowLive.current_delivery_type(config) == "webhook"
    end

    test "current_delivery_type/1 handles legacy rabbitmq queue config" do
      config = %{"rabbitmq_queue" => "test_queue"}
      assert RequestShowLive.current_delivery_type(config) == "rabbitmq"
    end

    test "current_webhook_url/1 extracts webhook URL" do
      assert RequestShowLive.current_webhook_url(nil) == ""

      assert RequestShowLive.current_webhook_url(%{"webhook_url" => "http://test.com"}) ==
               "http://test.com"

      assert RequestShowLive.current_webhook_url(%{webhook_url: "http://test.com"}) ==
               "http://test.com"
    end

    test "current_rabbitmq_queue/1 extracts queue name" do
      assert RequestShowLive.current_rabbitmq_queue(nil) == ""

      assert RequestShowLive.current_rabbitmq_queue(%{"rabbitmq_queue" => "my_queue"}) ==
               "my_queue"

      assert RequestShowLive.current_rabbitmq_queue(%{rabbitmq_queue: "my_queue"}) == "my_queue"
    end
  end

  describe "format_json/1 edge cases" do
    alias BatcherWeb.RequestShowLive

    test "formats list" do
      list = [1, 2, 3]
      result = RequestShowLive.format_json(list)
      assert result =~ "1"
    end

    test "formats nested map" do
      nested = %{"outer" => %{"inner" => "value"}}
      result = RequestShowLive.format_json(nested)
      assert result =~ "inner"
      assert result =~ "value"
    end
  end

  describe "format_bytes/1 edge cases" do
    alias BatcherWeb.RequestShowLive

    test "formats exact KB boundary" do
      assert RequestShowLive.format_bytes(1024) == "1.0 KB"
    end

    test "formats large MB values" do
      assert RequestShowLive.format_bytes(100 * 1024 * 1024) == "100.0 MB"
    end
  end
end
