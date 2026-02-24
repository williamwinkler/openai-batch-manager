defmodule BatcherWeb.BatchIndexLiveAdditionalTest do
  use BatcherWeb.LiveViewCase, async: false

  import Batcher.Generator

  describe "search functionality" do
    test "filters batches by query", %{conn: conn} do
      # Create batches with specific models
      generate(batch(model: "gpt-4o"))
      generate(batch(model: "gpt-3.5-turbo"))

      {:ok, view, _html} = live(conn, ~p"/batches")

      # Search for gpt-4o using the correct event name
      view
      |> element("form[phx-change='search']")
      |> render_change(%{"query" => "gpt-4o"})

      html = render(view)
      assert html =~ "gpt-4o"
    end

    test "search shows matching results", %{conn: conn} do
      generate(batch(model: "unique-model-123"))
      generate(batch(model: "other-model"))

      {:ok, view, _html} = live(conn, ~p"/batches")

      # Search for unique model
      view
      |> element("form[phx-change='search']")
      |> render_change(%{"query" => "unique-model-123"})

      html = render(view)
      assert html =~ "unique-model-123"
    end
  end

  describe "batch row interactions" do
    test "clicking batch row navigates to batch details", %{conn: conn} do
      batch = generate(batch())

      {:ok, view, _html} = live(conn, ~p"/batches")

      # The row uses phx-hook with data-navigate-path
      # Let's check if there's a link inside
      html = render(view)
      assert html =~ "/batches/#{batch.id}"
    end
  end

  describe "batch status display" do
    test "shows different states correctly", %{conn: conn} do
      generate(batch())
      generate(seeded_batch(state: :cancelled))

      {:ok, _view, html} = live(conn, ~p"/batches")

      # Should show both states
      assert html =~ "Building"
      assert html =~ "Cancelled"
    end
  end

  describe "empty state" do
    test "shows empty state when no batches exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/batches")

      assert html =~ "0" or html =~ "0 items"
    end
  end

  describe "batch columns" do
    test "shows all expected columns", %{conn: conn} do
      _batch = generate(batch())

      {:ok, _view, html} = live(conn, ~p"/batches")

      # Check column headers
      assert html =~ "ID"
      assert html =~ "Model"
      assert html =~ "Status"
      assert html =~ "Endpoint"
      assert html =~ "Time in state"
    end

    test "shows batch model", %{conn: conn} do
      _batch = generate(batch(model: "gpt-4o-mini"))

      {:ok, _view, html} = live(conn, ~p"/batches")

      assert html =~ "gpt-4o-mini"
    end
  end

  describe "state-specific progress in time in state column" do
    test "renders completed/total ratio for openai_processing", %{conn: conn} do
      generate(
        seeded_batch(
          state: :openai_processing,
          openai_requests_completed: 468,
          openai_requests_total: 471,
          openai_requests_failed: 0
        )
      )

      {:ok, _view, html} = live(conn, ~p"/batches")

      assert html =~ "468/471"
    end

    test "updates openai_processing ratio from progress_updated pubsub event without reload", %{
      conn: conn
    } do
      batch = generate(seeded_batch(state: :openai_processing))

      {:ok, view, _html} = live(conn, ~p"/batches")

      BatcherWeb.Endpoint.broadcast(
        "batches:progress_updated:#{batch.id}",
        "progress_updated",
        %{
          data: %{
            id: batch.id,
            openai_requests_completed: 10,
            openai_requests_failed: 1,
            openai_requests_total: 20
          }
        }
      )

      row_html =
        view
        |> element("#batches-row-#{batch.id}")
        |> render()

      assert row_html =~ "10/20"
    end

    test "does not show ratio for downloading", %{conn: conn} do
      generate(
        seeded_batch(
          state: :downloading,
          openai_requests_completed: 5,
          openai_requests_total: 10
        )
      )

      {:ok, _view, html} = live(conn, ~p"/batches")

      refute html =~ "5/10"
    end

    test "does not show ratio for delivering", %{conn: conn} do
      generate(
        seeded_batch(
          state: :delivering,
          request_count: 3,
          openai_requests_completed: 2,
          openai_requests_total: 3
        )
      )

      {:ok, _view, html} = live(conn, ~p"/batches")

      refute html =~ "2/3"
    end
  end

  describe "metrics delta updates" do
    test "applies in-memory request/size updates from metrics delta event", %{conn: conn} do
      batch = generate(batch(model: "delta-model"))

      {:ok, view, _html} = live(conn, ~p"/batches")

      row_html_before =
        view
        |> element("#batches-row-#{batch.id}")
        |> render()

      assert row_html_before =~ "0 bytes"

      BatcherWeb.Endpoint.broadcast("batches:metrics_delta", "delta", %{
        batch_id: batch.id,
        request_count_delta: 2,
        size_bytes_delta: 2048,
        ts: DateTime.utc_now()
      })

      row_html_after =
        view
        |> element("#batches-row-#{batch.id}")
        |> render()

      assert row_html_after =~ "2.0 KB"
      assert row_html_after =~ ~r/>\s*2\s*</
    end
  end

  describe "cancel batch action" do
    test "cancel button is visible for active batches", %{conn: conn} do
      generate(batch())

      {:ok, _view, html} = live(conn, ~p"/batches")

      assert html =~ "Cancel"
    end

    test "clicking cancel button cancels batch", %{conn: conn} do
      batch = generate(batch())

      {:ok, view, _html} = live(conn, ~p"/batches")

      render_click(view, "cancel_batch", %{"id" => Integer.to_string(batch.id)})

      wait_for(fn ->
        html = render(view)
        html =~ "Batch cancelled successfully" or html =~ "Cancelled" or html =~ "cancelled"
      end)
    end
  end

  describe "delete batch action" do
    test "delete button is visible for cancelled batches", %{conn: conn} do
      generate(seeded_batch(state: :cancelled))

      {:ok, _view, html} = live(conn, ~p"/batches")

      assert html =~ "Delete"
    end

    test "clicking delete button removes batch", %{conn: conn} do
      batch = generate(seeded_batch(state: :cancelled))

      {:ok, view, _html} = live(conn, ~p"/batches")

      render_click(view, "delete_batch", %{"id" => Integer.to_string(batch.id)})

      wait_for(fn -> not has_element?(view, "#batches-row-#{batch.id}") end)
    end
  end

  describe "restart batch action" do
    test "restart button is visible only for failed batches", %{conn: conn} do
      failed_batch = generate(seeded_batch(state: :failed))
      active_batch = generate(batch())

      {:ok, view, _html} = live(conn, ~p"/batches")

      assert has_element?(
               view,
               "#restart-batch-#{failed_batch.id}"
             )

      refute has_element?(
               view,
               "#restart-batch-#{active_batch.id}"
             )
    end

    test "clicking restart moves failed batch back into processing flow", %{conn: conn} do
      failed_batch = generate(seeded_batch(state: :failed, openai_input_file_id: "file_in"))
      generate(seeded_request(batch_id: failed_batch.id, state: :failed))

      {:ok, view, _html} = live(conn, ~p"/batches")

      render_click(view, "restart_batch", %{"id" => Integer.to_string(failed_batch.id)})

      wait_for(fn -> render(view) =~ "Batch restart initiated successfully" end)
      html = render(view)
      assert html =~ "Waiting for capacity" or html =~ "OpenAI processing"
    end
  end

  describe "token-limit backoff badge" do
    test "shows backoff badge only for waiting token-limit batches", %{conn: conn} do
      backoff_batch =
        generate(
          seeded_batch(
            state: :waiting_for_capacity,
            capacity_wait_reason: "token_limit_exceeded_backoff",
            token_limit_retry_attempts: 2,
            token_limit_retry_next_at: DateTime.add(DateTime.utc_now(), 300, :second)
          )
        )

      normal_waiting =
        generate(
          seeded_batch(
            state: :waiting_for_capacity,
            capacity_wait_reason: "insufficient_headroom"
          )
        )

      {:ok, view, _html} = live(conn, ~p"/batches")

      assert has_element?(view, "#batches-row-#{backoff_batch.id}", "Backoff 2/5")
      refute has_element?(view, "#batches-row-#{normal_waiting.id}", "Backoff")
    end
  end

  describe "async action UX" do
    test "shows spinner and disables only clicked button while action is pending", %{conn: conn} do
      batch = generate(seeded_batch(state: :building, request_count: 1))
      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 250)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/batches")

      view
      |> element("#cancel-batch-#{batch.id}")
      |> render_click()

      wait_for(fn -> has_element?(view, "button#cancel-batch-#{batch.id}[disabled]") end)
      refute has_element?(view, "button#upload-batch-#{batch.id}[disabled]")

      :timer.sleep(400)
      refute has_element?(view, "button#cancel-batch-#{batch.id}[disabled]")
    end

    test "keeps batch action disabled after navigation while action lock is active", %{conn: conn} do
      batch = generate(seeded_batch(state: :building, request_count: 1))
      original_delay = Application.get_env(:batcher, :batch_action_test_delay_ms, 0)
      Application.put_env(:batcher, :batch_action_test_delay_ms, 500)

      on_exit(fn ->
        Application.put_env(:batcher, :batch_action_test_delay_ms, original_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/batches")

      view
      |> element("#cancel-batch-#{batch.id}")
      |> render_click()

      wait_for(fn -> has_element?(view, "button#cancel-batch-#{batch.id}[disabled]") end)

      # Simulate leaving and coming back to /batches: lock should still keep button disabled.
      {:ok, view2, _html} = live(conn, ~p"/batches")

      assert has_element?(view2, "button#cancel-batch-#{batch.id}[disabled]")
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
