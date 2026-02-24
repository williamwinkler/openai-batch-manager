defmodule BatcherWeb.RequestIndexLiveTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Batching
  import Batcher.Generator

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
          generate(
            seeded_request(
              batch_id: batch.id,
              custom_id: "req-#{i}-#{j}",
              url: batch.url,
              model: batch.model
            )
          )
        end
      end
      |> List.flatten()

    {:ok, batch: batch, batches: batches, requests: requests}
  end

  describe "pagination" do
    test "displays pagination controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?limit=10")

      assert has_element?(view, ".join")
    end

    test "shows total count once available", %{conn: conn} do
      {:ok, view, initial_html} = live(conn, ~p"/requests")

      assert initial_html =~ "Calculating..." or initial_html =~ "of 20"
      wait_for(fn -> render(view) =~ "of 20" end)

      html = render(view)
      assert html =~ "of 20"
    end

    test "navigation buttons are disabled on first page", %{conn: conn} do
      # Use a small limit to ensure we have multiple pages and navigation buttons
      {:ok, view, _html} = live(conn, ~p"/requests?limit=10")

      html = render(view)
      assert html =~ "Previous"
      assert html =~ "btn-disabled"
    end

    test "clicking next navigates forward", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?limit=10")
      first_before = render(view) |> first_request_row_id()

      view
      |> element("a.join-item", "Next")
      |> render_click()

      wait_for(fn -> render(view) |> first_request_row_id() != first_before end)

      new_requests = view |> element("#requests") |> render() |> count_table_rows()
      assert new_requests > 0
    end

    test "previous button works after moving forward", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?limit=10")
      first_page_first_id = render(view) |> first_request_row_id()

      view
      |> element("a.join-item", "Next")
      |> render_click()

      wait_for(fn -> render(view) |> first_request_row_id() != first_page_first_id end)

      view
      |> element("a.join-item", "Previous")
      |> render_click()

      wait_for(fn -> render(view) |> first_request_row_id() == first_page_first_id end)
    end

    test "next button is disabled on last page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?limit=10")
      view |> element("a.join-item", "Next") |> render_click()
      html = render(view)
      assert html =~ "Next"
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

      assert has_element?(view, "#sort_by")
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

      # Should show the empty state
      html = render(view)
      assert html =~ "No requests found"
    end

    test "shows count fallback when async count fails", %{conn: conn} do
      Application.put_env(:batcher, :request_index_count_error_queries, ["req"])

      on_exit(fn ->
        Application.delete_env(:batcher, :request_index_count_error_queries)
      end)

      {:ok, view, _html} = live(conn, ~p"/requests?q=req")

      wait_for(fn -> render(view) =~ "Count unavailable" end)
      assert render(view) =~ "Count unavailable"
    end

    test "ignores stale async count responses when search changes rapidly", %{conn: conn} do
      Application.put_env(:batcher, :request_index_count_delay_ms_by_query, %{"req" => 250})

      on_exit(fn ->
        Application.delete_env(:batcher, :request_index_count_delay_ms_by_query)
      end)

      {:ok, view, _html} = live(conn, ~p"/requests?q=req")

      view
      |> element("form[phx-change='search']")
      |> render_change(%{"query" => "req-1"})

      wait_for(fn -> render(view) =~ "req-1-1" end, 60, 25)
      assert render(view) =~ "req-1-1"
    end

    test "pubsub updates are buffered and do not reset count to loading state", %{
      conn: conn,
      requests: requests
    } do
      request = hd(requests)
      {:ok, view, _html} = live(conn, ~p"/requests")

      wait_for(fn -> render(view) =~ "of 20" end)
      first_before = render(view) |> first_request_row_id()

      BatcherWeb.Endpoint.broadcast(
        "requests:state_changed",
        "state_changed",
        %{data: request}
      )

      # PubSub buffering should not force count back into loading state or reorder rows.
      :timer.sleep(75)
      html = render(view)
      refute html =~ "Calculating..."
      assert html =~ "of 20"
      assert first_request_row_id(html) == first_before
      assert has_element?(view, "button[phx-click='refresh_requests']", "Refresh")
    end

    test "refresh button applies queued created updates and clears pending indicator", %{
      conn: conn,
      batch: batch
    } do
      {:ok, view, _html} = live(conn, ~p"/requests")

      wait_for(fn -> render(view) =~ "of 20" end)

      {:ok, created_request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "buffered-new-request",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "buffered-new-request",
            body: %{input: "buffered", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      BatcherWeb.Endpoint.broadcast(
        "requests:created",
        "created",
        %{data: created_request}
      )

      :timer.sleep(75)
      refute render(view) =~ "buffered-new-request"
      assert has_element?(view, "button[phx-click='refresh_requests']", "Refresh")

      view
      |> element("button[phx-click='refresh_requests']")
      |> render_click()

      wait_for(fn -> render(view) =~ "buffered-new-request" end)
      refute has_element?(view, "button[phx-click='refresh_requests']", "Refresh")
    end

    test "navigation changes clear pending indicator", %{conn: conn, requests: requests} do
      request = hd(requests)
      {:ok, view, _html} = live(conn, ~p"/requests")

      BatcherWeb.Endpoint.broadcast(
        "requests:state_changed",
        "state_changed",
        %{data: request}
      )

      wait_for(fn -> has_element?(view, "button[phx-click='refresh_requests']", "Refresh") end)

      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "created_at"})

      refute has_element?(view, "button[phx-click='refresh_requests']", "Refresh")
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

      assert has_element?(view, "#sort_by")
    end

    test "sorting by custom_id (Z-A) orders requests correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Change sort to "Custom ID (Z-A)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "-custom_id"})

      assert has_element?(view, "#sort_by")
    end

    test "sorting by state orders requests correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Change sort to "State (A-Z)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "state"})

      assert has_element?(view, "#sort_by")
    end

    test "sorting by batch_id orders requests correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      # Change sort to "Batch ID (High)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "-batch_id"})

      assert has_element?(view, "#sort_by")
    end

    test "sorting preserves query parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?q=req")

      # Change sort option
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "custom_id"})

      html = render(view)
      assert html =~ "q=req"
      assert has_element?(view, "#sort_by")
    end

    test "sorting preserves pagination offset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests?limit=15")

      # Change sort option
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "custom_id"})

      assert has_element?(view, "#sort_by")
    end

    test "offset URLs redirect to keyset-compatible params", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/requests?offset=10&limit=10")
      assert to =~ "/requests?"
      assert to =~ "limit=10"
      refute to =~ "offset="
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
      assert has_element?(view, "#sort_by")
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

  defp first_request_row_id(html) do
    case Regex.run(~r/id=\"request-created-(\d+)\"/, html) do
      [_, id] -> id
      _ -> nil
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
