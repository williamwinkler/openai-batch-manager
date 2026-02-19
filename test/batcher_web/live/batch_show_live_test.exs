defmodule BatcherWeb.BatchShowLiveTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Batching

  import Batcher.Generator

  setup do
    batch = generate(batch())

    # Add some requests to the batch
    {:ok, request} =
      Batching.create_request(%{
        batch_id: batch.id,
        custom_id: "test_req_1",
        url: batch.url,
        model: batch.model,
        request_payload: %{
          custom_id: "test_req_1",
          body: %{input: "test", model: batch.model},
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
    test "displays batch details", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      assert html =~ "Batch #{batch.id}"
      assert html =~ batch.model
      assert html =~ to_string(batch.url)
    end

    test "shows batch state", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      # The batch should be in "building" state (check for the status badge)
      assert html =~ "Building" or html =~ "building"
    end

    test "redirects to root when batch not found", %{conn: conn} do
      {:ok, conn} =
        live(conn, ~p"/batches/999999")
        |> follow_redirect(conn)

      assert html_response(conn, 200) =~ "Batch not found"
    end
  end

  describe "upload_batch event" do
    test "upload button is visible for building batches", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      assert html =~ "Upload Batch"
    end

    test "starts batch upload when clicked", %{conn: conn, batch: batch} do
      {:ok, view, _html} = live(conn, ~p"/batches/#{batch.id}")

      # Click the upload button
      view
      |> element("button[phx-click='upload_batch']")
      |> render_click()

      # The batch state should change
      :timer.sleep(150)
      html = render(view)
      assert html =~ "uploading" or html =~ "Batch upload started"
    end
  end

  describe "cancel_batch event" do
    test "cancel button is visible for building batches", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      assert html =~ "Cancel Batch"
    end

    test "cancels the batch when clicked", %{conn: conn, batch: batch} do
      {:ok, view, _html} = live(conn, ~p"/batches/#{batch.id}")

      # Click the cancel button
      view
      |> element("button[phx-click='cancel_batch']")
      |> render_click()

      :timer.sleep(150)
      html = render(view)
      assert html =~ "Batch cancelled successfully" or html =~ "cancelled"
    end
  end

  describe "delete_batch event" do
    test "delete button is visible for cancelled batches", %{conn: conn, batch: batch} do
      # First cancel the batch
      {:ok, cancelled_batch} = Batching.cancel_batch(batch)

      {:ok, _view, html} = live(conn, ~p"/batches/#{cancelled_batch.id}")

      assert html =~ "Delete Batch"
    end

    test "deletes the batch and redirects", %{conn: conn, batch: batch} do
      # First cancel the batch so delete is available
      {:ok, cancelled_batch} = Batching.cancel_batch(batch)

      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 150)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/batches/#{cancelled_batch.id}")

      # Click delete button
      view
      |> element("button[phx-click='delete_batch']")
      |> render_click()

      assert has_element?(view, "button#delete-batch[disabled]", "Deleting...")

      # Should redirect to batches list
      assert_redirect(view, ~p"/batches", 1_000)
    end
  end

  describe "timeline display" do
    test "shows timeline section", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      # Should have timeline section
      assert html =~ "Timeline"
    end

    test "shows future expected states when waiting for capacity", %{conn: conn} do
      batch = generate(seeded_batch(state: :waiting_for_capacity))

      {:ok, view, _html} = live(conn, ~p"/batches/#{batch.id}")

      :timer.sleep(120)
      html = render(view)
      assert html =~ "OpenAI processing"
      assert html =~ "OpenAI completed"
    end
  end

  describe "pubsub updates" do
    test "updates when batch state changes via pubsub", %{conn: conn, batch: batch} do
      {:ok, view, _html} = live(conn, ~p"/batches/#{batch.id}")

      # Cancel the batch to trigger a state change
      {:ok, _updated_batch} = Batching.cancel_batch(batch)

      # Wait for PubSub update
      :timer.sleep(100)

      html = render(view)
      assert html =~ "cancelled"
    end
  end

  describe "batch details" do
    test "shows request count", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      assert html =~ "Requests"
    end

    test "shows batch size", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      assert html =~ "Size"
    end

    test "shows created date", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      assert html =~ "Created"
    end
  end

  describe "openai progress display" do
    test "shows progress counter in openai section", %{conn: conn} do
      batch =
        generate(
          seeded_batch(
            openai_requests_completed: 5,
            openai_requests_failed: 2,
            openai_requests_total: 10
          )
        )

      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      assert html =~ "Progress"
      assert html =~ "5/10"
    end

    test "updates progress via pubsub progress_updated event", %{conn: conn} do
      batch = generate(batch())

      {:ok, view, _html} = live(conn, ~p"/batches/#{batch.id}")

      BatcherWeb.Endpoint.broadcast(
        "batches:progress_updated:#{batch.id}",
        "progress_updated",
        %{
          data: %{
            id: batch.id,
            openai_requests_completed: 7,
            openai_requests_failed: 1,
            openai_requests_total: 9
          }
        }
      )

      html = render(view)
      assert html =~ "7/9"
    end
  end

  describe "capacity reason rendering" do
    test "renders insufficient_headroom message and does not render fairness message", %{
      conn: conn
    } do
      batch =
        generate(
          seeded_batch(
            state: :waiting_for_capacity,
            capacity_wait_reason: "insufficient_headroom"
          )
        )

      {:ok, view, _html} = live(conn, ~p"/batches/#{batch.id}")

      view
      |> element("button[phx-click='open_capacity_modal']")
      |> render_click()

      html = render(view)

      assert html =~ "Why This Batch Is Waiting"
      assert html =~ "starting it now would exceed the rate limit and cause errors"
      refute html =~ "Older waiting batch has priority (FIFO)"
    end
  end

  describe "restart batch action" do
    test "restart button is visible for failed batches", %{conn: conn} do
      failed_batch = generate(seeded_batch(state: :failed))

      {:ok, _view, html} = live(conn, ~p"/batches/#{failed_batch.id}")

      assert html =~ "Restart Batch"
    end

    test "clicking restart transitions failed batch back into processing flow", %{conn: conn} do
      failed_batch = generate(seeded_batch(state: :failed, openai_input_file_id: "file_in"))
      generate(seeded_request(batch_id: failed_batch.id, state: :failed))

      {:ok, view, _html} = live(conn, ~p"/batches/#{failed_batch.id}")

      view
      |> element("button[phx-click='restart_batch']")
      |> render_click()

      :timer.sleep(150)
      html = render(view)
      assert html =~ "Batch restart initiated successfully"
      assert html =~ "Waiting for capacity" or html =~ "OpenAI processing"
    end
  end

  describe "async action UX" do
    test "shows cancel spinner while pending", %{conn: conn, batch: batch} do
      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 250)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/batches/#{batch.id}")

      view
      |> element("button[phx-click='cancel_batch']")
      |> render_click()

      assert has_element?(view, "button#cancel-batch[disabled]", "Cancelling...")

      :timer.sleep(400)
      refute render(view) =~ "Cancelling..."
    end
  end

  describe "batch error modal" do
    test "opens and closes modal for JSON error", %{conn: conn} do
      batch =
        generate(
          seeded_batch(
            state: :failed,
            error_msg: ~s({"error":{"message":"boom","code":"bad_request"}})
          )
        )

      {:ok, view, _html} = live(conn, ~p"/batches/#{batch.id}")

      view
      |> element("div[phx-click='show_batch_error']")
      |> render_click()

      html = render(view)
      assert html =~ "Batch Error"
      assert html =~ "boom"
      assert html =~ "bad_request"
      assert has_element?(view, "button[phx-click='close_batch_error_modal']")

      view
      |> element("button[phx-click='close_batch_error_modal']")
      |> render_click()

      refute has_element?(view, "button[phx-click='close_batch_error_modal']")
    end

    test "shows plain text for non-json error", %{conn: conn} do
      batch =
        generate(
          seeded_batch(
            state: :failed,
            error_msg: "Something went wrong without JSON"
          )
        )

      {:ok, view, _html} = live(conn, ~p"/batches/#{batch.id}")

      view
      |> element("div[phx-click='show_batch_error']")
      |> render_click()

      html = render(view)
      assert html =~ "Batch Error"
      assert html =~ "Something went wrong without JSON"
    end
  end

  describe "token-limit backoff visibility" do
    test "shows backoff panel for token_limit_exceeded_backoff waiting batch", %{conn: conn} do
      batch =
        generate(
          seeded_batch(
            state: :waiting_for_capacity,
            capacity_wait_reason: "token_limit_exceeded_backoff",
            token_limit_retry_attempts: 2,
            token_limit_retry_next_at: DateTime.add(DateTime.utc_now(), 300, :second)
          )
        )

      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      assert html =~ "OpenAI Queue Backoff"
      assert html =~ "Retry attempt"
      assert html =~ "2/5"
      assert html =~ "This batch will retry automatically"
    end
  end
end
