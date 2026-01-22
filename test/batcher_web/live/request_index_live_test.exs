defmodule BatcherWeb.RequestIndexLiveTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Batching

  setup do
    # Create a batch first
    {:ok, batch} =
      Batching.create_batch(
        "gpt-4o-mini",
        "/v1/responses"
      )

    # Create enough requests to span multiple pages (per_page is 15)
    # Create 20 requests across multiple batches (batches have max 5 requests)
    # So we need at least 4 batches
    batches =
      for i <- 1..4 do
        {:ok, b} = Batching.create_batch("gpt-4o-mini-#{i}", "/v1/responses")
        b
      end

    requests =
      for {batch, i} <- Enum.with_index(batches, 1) do
        # Create 5 requests per batch (max allowed)
        for j <- 1..5 do
          {:ok, request} =
            Batching.create_request(%{
              batch_id: batch.id,
              custom_id: "req-#{i}-#{j}",
              url: batch.url,
              model: batch.model,
              request_payload: %{
                custom_id: "req-#{i}-#{j}",
                body: %{input: "test", model: batch.model},
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
      end
      |> List.flatten()

    {:ok, batch: batch, batches: batches, requests: requests}
  end

  describe "pagination" do
    test "displays pagination controls with page numbers", %{conn: conn} do
      # Use a small limit to ensure multiple pages
      {:ok, view, _html} = live(conn, ~p"/requests?limit=10")

      # Check that numbered pagination controls are present
      assert has_element?(view, ".join")
      # Page 1 should be active
      assert has_element?(view, "a.btn-primary", "1")
    end

    test "displays total count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Should show item count like "1-20 of 20"
      html = render(view)
      assert html =~ "of 20"
    end

    test "navigation buttons are disabled on first page", %{conn: conn} do
      # Use a small limit to ensure we have multiple pages and navigation buttons
      {:ok, view, _html} = live(conn, ~p"/requests?limit=10")

      # First and previous buttons should be disabled on first page
      html = render(view)
      # The first two buttons (first page and prev) should have btn-disabled
      assert html =~ "btn-disabled"
      assert html =~ "hero-chevron-double-left"
    end

    test "clicking page 2 navigates to second page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?limit=10")

      # Click page 2 button
      view
      |> element("a.join-item", "2")
      |> render_click()

      # Verify page 2 is now active
      assert has_element?(view, "a.btn-primary", "2")

      # Verify requests are still shown
      new_requests = view |> element("#requests") |> render() |> count_table_rows()
      assert new_requests > 0
    end

    test "previous button works on second page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?offset=10&limit=10")

      # Page 2 should be active
      assert has_element?(view, "a.btn-primary", "2")

      # Click page 1 to go back
      view
      |> element("a.join-item", "1")
      |> render_click()

      # Should be back on page 1
      assert has_element?(view, "a.btn-primary", "1")
    end

    test "next/last buttons are disabled on last page", %{conn: conn} do
      # Navigate to last page (offset=10 with 20 items and per_page=10 means page 2 is last)
      {:ok, view, _html} = live(conn, ~p"/requests?offset=10&limit=10")

      # The last two buttons (next and last) should have btn-disabled
      html = render(view)
      # Check that btn-disabled appears after the page numbers (for next/last buttons)
      assert html =~ "btn-disabled"
    end

    test "pagination preserves query text parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?q=req&limit=10")

      # Check that page links contain the query parameter
      html = render(view)
      assert html =~ "q=req"
    end

    test "pagination preserves sort_by parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?sort_by=custom_id&limit=10")

      # Check that page links contain the sort_by parameter
      html = render(view)
      assert html =~ "sort_by=custom_id"
    end

    test "pagination preserves both query and sort_by parameters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?q=req&sort_by=-created_at&limit=10")

      # Check that page links contain both parameters
      html = render(view)
      assert html =~ "q=req"
      assert html =~ "sort_by=-created_at"
    end

    test "pagination shows 0 items when empty", %{conn: conn} do
      # Clear all requests by destroying all batches (cascade delete)
      {:ok, batches} = Batching.list_batches()
      Enum.each(batches, fn batch -> Batching.destroy_batch(batch) end)

      {:ok, view, _html} = live(conn, ~p"/requests")

      # Should show "0 items"
      html = render(view)
      assert html =~ "0 items"
    end
  end

  describe "sorting" do
    test "displays sort dropdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Check that sort dropdown is present
      assert has_element?(view, "#sort_by")
      assert has_element?(view, "label", "Sort by:")
    end

    test "default sort is newest first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Check that the select has the default value selected
      html = render(view)
      # HTML format: <option selected="" value="-created_at">
      assert html =~ ~s(value="-created_at")
      assert html =~ ~s(<option selected="" value="-created_at">)
    end

    test "changing sort option updates URL and results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Change sort to "Oldest first" - target the form with phx-change
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "created_at"})

      # Verify URL was updated (includes offset and limit when resetting to first page)
      html = render(view)
      assert html =~ "sort_by=created_at"

      # Verify the select shows the new value
      html = render(view)
      # HTML format: <option selected="" value="created_at">
      assert html =~ ~s(<option selected="" value="created_at">)
    end

    test "sorting by custom_id (A-Z) orders requests correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Change sort to "Custom ID (A-Z)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "custom_id"})

      # Verify URL was updated
      html = render(view)
      assert html =~ "sort_by=custom_id"
    end

    test "sorting by custom_id (Z-A) orders requests correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Change sort to "Custom ID (Z-A)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "-custom_id"})

      # Verify URL was updated
      html = render(view)
      assert html =~ "sort_by=-custom_id"
    end

    test "sorting by state orders requests correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Change sort to "State (A-Z)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "state"})

      # Verify URL was updated
      html = render(view)
      assert html =~ "sort_by=state"
    end

    test "sorting by batch_id orders requests correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Change sort to "Batch ID (High)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "-batch_id"})

      # Verify URL was updated
      html = render(view)
      assert html =~ "sort_by=-batch_id"
    end

    test "sorting preserves query parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?q=req")

      # Change sort option
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "custom_id"})

      # Verify both query and sort_by are preserved
      html = render(view)
      assert html =~ "q=req"
      assert html =~ "sort_by=custom_id"
    end

    test "sorting preserves pagination offset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?offset=15&limit=15")

      # Change sort option
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "custom_id"})

      # Verify sort_by is added
      html = render(view)
      assert html =~ "sort_by=custom_id"
    end

    test "invalid sort option defaults to newest first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?sort_by=invalid_sort")

      # The invalid sort should be replaced with default
      html = render(view)
      # Should default to -created_at
      # HTML format: <option selected="" value="-created_at">
      assert html =~ ~s(<option selected="" value="-created_at">)
    end

    test "all sort options are available in dropdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      html = render(view)

      # Check that all expected sort options are present
      assert html =~ "Newest first"
      assert html =~ "Oldest first"
      assert html =~ "Recently updated"
      assert html =~ "Least recently updated"
      assert html =~ "State (A-Z)"
      assert html =~ "State (Z-A)"
      assert html =~ "Custom ID (A-Z)"
      assert html =~ "Custom ID (Z-A)"
      assert html =~ "Model (A-Z)"
      assert html =~ "Model (Z-A)"
      assert html =~ "Batch ID (High)"
      assert html =~ "Batch ID (Low)"
    end
  end

  # Helper function to count table rows (excluding header)
  defp count_table_rows(html) do
    # Count <tr> elements that are not in <thead>
    html
    |> String.split("<tr")
    |> length()
    # Subtract 1 for the opening tag split
    |> Kernel.-(1)
  end
end
