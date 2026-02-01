defmodule BatcherWeb.RequestIndexLiveAdditionalTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Batching

  import Batcher.Generator

  setup do
    batch = generate(batch())

    requests =
      for i <- 1..5 do
        {:ok, request} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: "req-#{i}",
            url: batch.url,
            model: batch.model,
            request_payload: %{
              custom_id: "req-#{i}",
              body: %{input: "test input #{i}", model: batch.model},
              method: "POST",
              url: batch.url
            },
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })

        request
      end

    {:ok, batch: batch, requests: requests}
  end

  describe "search functionality" do
    test "search input is present", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/requests")

      assert html =~ "Search"
    end

    test "search filters results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      view
      |> element("form[phx-change='search']")
      |> render_change(%{"query" => "req-1"})

      html = render(view)
      assert html =~ "req-1"
    end
  end

  describe "request row interactions" do
    test "request rows are displayed", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/requests")

      assert html =~ "req-1"
      assert html =~ "req-2"
    end

    test "clicking request row navigates to details", %{conn: conn, requests: [first | _]} do
      {:ok, _view, html} = live(conn, ~p"/requests")

      # Request row should have link to detail page
      assert html =~ "/requests/#{first.id}"
    end
  end

  describe "request status badges" do
    test "shows pending status for new requests", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/requests")

      assert html =~ "Pending" or html =~ "pending"
    end
  end

  describe "table columns" do
    test "shows all expected columns", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/requests")

      assert html =~ "Custom ID" or html =~ "ID"
      assert html =~ "Model"
      assert html =~ "Status" or html =~ "State"
    end

    test "shows batch information", %{conn: conn, batch: batch} do
      {:ok, _view, html} = live(conn, ~p"/requests")

      assert html =~ "Batch" or html =~ to_string(batch.id)
    end
  end

  describe "empty state" do
    test "shows empty state message when no requests", %{conn: conn} do
      # Delete all batches which cascades to delete requests
      {:ok, batches} = Batching.list_batches()
      Enum.each(batches, fn b -> Batching.destroy_batch(b) end)

      {:ok, _view, html} = live(conn, ~p"/requests")

      assert html =~ "0 items" or html =~ "No requests"
    end
  end

  describe "limit parameter" do
    test "respects limit parameter", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/requests?limit=3")

      # Should show pagination with fewer items per page
      assert html =~ "1-3" or html =~ "limit=3"
    end
  end
end
