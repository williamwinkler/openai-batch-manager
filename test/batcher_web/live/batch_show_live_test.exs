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

      html = render(view)
      assert html =~ "cancelled"
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

      {:ok, view, _html} = live(conn, ~p"/batches/#{cancelled_batch.id}")

      # Click delete button
      view
      |> element("button[phx-click='delete_batch']")
      |> render_click()

      # Should redirect to root
      assert_redirect(view, ~p"/")
    end
  end

  describe "timeline display" do
    test "shows timeline section", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/batches/#{batch.id}")

      # Should have timeline section
      assert html =~ "Timeline"
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
end
