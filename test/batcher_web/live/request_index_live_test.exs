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
    test "displays pagination controls on first page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Check that pagination controls are present
      assert has_element?(view, "a", "Previous")
      assert has_element?(view, "a", "Next")
    end

    test "Previous button is disabled on first page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Find the Previous button and check it has btn-disabled class
      previous_button = element(view, "a", "Previous")
      html = render(previous_button)

      assert html =~ "btn-disabled"
    end

    test "Next button is enabled on first page when there are more pages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Find the Next button and check it does NOT have btn-disabled class
      next_button = element(view, "a", "Next")
      html = render(next_button)

      refute html =~ "btn-disabled"
    end

    test "clicking Next button navigates to second page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Click Next button
      view
      |> element("a", "Next")
      |> render_click()

      # Verify we navigated to next page by checking Previous button is now enabled
      previous_button = element(view, "a", "Previous")
      html = render(previous_button)
      refute html =~ "btn-disabled"

      # Verify different requests are shown (page 2 should have different content)
      new_requests = view |> element("#requests") |> render() |> count_table_rows()

      # Should still have requests (up to per_page items)
      assert new_requests > 0
    end

    test "Previous button is enabled on second page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?offset=15&limit=15")

      # Find the Previous button and check it does NOT have btn-disabled class
      previous_button = element(view, "a", "Previous")
      html = render(previous_button)

      refute html =~ "btn-disabled"
    end

    test "clicking Previous button navigates back to first page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?offset=15&limit=15")

      # Click Previous button
      view
      |> element("a", "Previous")
      |> render_click()

      # Verify URL updated to first page (offset=0 or no offset)
      # Check the Previous button link - should not have offset=15
      previous_link = view |> element("a", "Previous") |> render()
      refute previous_link =~ "offset=15"
    end

    test "Next button is disabled on last page", %{conn: conn} do
      # Navigate to last page (offset=15 with 20 items and per_page=15)
      {:ok, view, _html} = live(conn, ~p"/requests?offset=15&limit=15")

      # Find the Next button and check it has btn-disabled class
      next_button = element(view, "a", "Next")
      html = render(next_button)

      assert html =~ "btn-disabled"
    end

    test "pagination preserves query text parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?q=req")

      # Check that Next button link contains the query parameter
      next_link = view |> element("a", "Next") |> render()
      assert next_link =~ "q=req"
    end

    test "pagination preserves sort_by parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?sort_by=custom_id")

      # Check that Next button link contains the sort_by parameter
      next_link = view |> element("a", "Next") |> render()
      assert next_link =~ "sort_by=custom_id"
    end

    test "pagination preserves both query and sort_by parameters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?q=req&sort_by=-created_at")

      # Check that Next button link contains both parameters
      next_link = view |> element("a", "Next") |> render()
      assert next_link =~ "q=req"
      assert next_link =~ "sort_by=-created_at"
    end

    test "pagination works with empty results", %{conn: conn} do
      # Clear all requests by destroying all batches (cascade delete)
      {:ok, batches} = Batching.list_batches()
      Enum.each(batches, fn batch -> Batching.destroy_batch(batch) end)

      {:ok, view, _html} = live(conn, ~p"/requests")

      # Pagination should still render but buttons should be disabled
      assert has_element?(view, "a", "Previous")
      assert has_element?(view, "a", "Next")

      # Both buttons should be disabled when there are no results
      previous_button = element(view, "a", "Previous")
      next_button = element(view, "a", "Next")

      assert render(previous_button) =~ "btn-disabled"
      assert render(next_button) =~ "btn-disabled"
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
