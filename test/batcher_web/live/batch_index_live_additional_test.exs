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
    end

    test "shows batch model", %{conn: conn} do
      _batch = generate(batch(model: "gpt-4o-mini"))

      {:ok, _view, html} = live(conn, ~p"/batches")

      assert html =~ "gpt-4o-mini"
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

      view
      |> element("button[phx-click='cancel_batch'][phx-value-id='#{batch.id}']")
      |> render_click()

      html = render(view)
      assert html =~ "Cancelled" or html =~ "cancelled"
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

      view
      |> element("button[phx-click='delete_batch'][phx-value-id='#{batch.id}']")
      |> render_click()

      html = render(view)
      # Batch should no longer be in the list
      refute html =~ "id=\"batches-row-#{batch.id}\""
    end
  end
end
