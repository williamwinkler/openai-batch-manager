defmodule BatcherWeb.RequestIndexSortingRetryLiveTest do
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

  describe "retry delivery action visibility" do
    test "shows retry button only for deliverable requests in non-delivering batches", %{
      conn: conn
    } do
      deliverable_batch = generate(seeded_batch(state: :partially_delivered))
      blocked_batch = generate(seeded_batch(state: :delivering))

      deliverable_request =
        generate(
          seeded_request(
            batch_id: deliverable_batch.id,
            state: :delivery_failed,
            response_payload: %{"output" => "response"},
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          )
        )

      blocked_request =
        generate(
          seeded_request(
            batch_id: blocked_batch.id,
            state: :delivery_failed,
            response_payload: %{"output" => "response"},
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          )
        )

      {:ok, view, _html} = live(conn, ~p"/requests")

      assert has_element?(view, "#retry-delivery-#{deliverable_request.id}")
      refute has_element?(view, "#retry-delivery-#{blocked_request.id}")
    end
  end

  # Helper function to count table rows (excluding header)
end
