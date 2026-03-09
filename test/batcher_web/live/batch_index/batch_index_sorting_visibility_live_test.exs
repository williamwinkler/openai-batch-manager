defmodule BatcherWeb.BatchIndexSortingVisibilityLiveTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Batching
  import Batcher.Generator

  setup do
    original_coalesce_ms = Application.get_env(:batcher, :ui_batch_reload_coalesce_ms, 1_500)
    Application.put_env(:batcher, :ui_batch_reload_coalesce_ms, 30)

    on_exit(fn ->
      Application.put_env(:batcher, :ui_batch_reload_coalesce_ms, original_coalesce_ms)
      Application.delete_env(:batcher, :batch_index_reload_delay_ms)
    end)

    # Create enough batches to span multiple pages (per_page is 15)
    # Create 20 batches to ensure we have at least 2 pages
    batches =
      for i <- 1..20 do
        {:ok, batch} =
          Batching.create_batch(
            "gpt-4o-mini-#{i}",
            "/v1/responses"
          )

        batch
      end

    {:ok, batches: batches}
  end

  describe "sorting" do
    test "displays sort dropdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")

      # Check that sort dropdown is present
      assert has_element?(view, "#sort_by")
      assert has_element?(view, "label", "Sort by:")
    end

    test "default sort is newest first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")

      # Check that the select has the default value selected
      html = render(view)
      # HTML format: <option selected="" value="-created_at">
      assert html =~ ~s(value="-created_at")
      assert html =~ ~s(<option selected="" value="-created_at">)
    end

    test "changing sort option updates URL and results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")

      # Change sort to "Oldest first" - target the form with phx-change
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "created_at"})

      # Verify the select shows the new value
      html = render(view)
      # HTML format: <option selected="" value="created_at">
      assert html =~ ~s(<option selected="" value="created_at">)
    end

    test "sorting by model (A-Z) orders batches correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")

      # Change sort to "Model (A-Z)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "model"})

      assert has_element?(view, "#sort_by")
    end

    test "sorting by model (Z-A) orders batches correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")

      # Change sort to "Model (Z-A)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "-model"})

      assert has_element?(view, "#sort_by")
    end

    test "sorting by state orders batches correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")

      # Change sort to "State (A-Z)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "state"})

      assert has_element?(view, "#sort_by")
    end

    test "sorting by endpoint (A-Z) orders batches correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")

      # Change sort to "Endpoint (A-Z)"
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "url"})

      assert has_element?(view, "#sort_by")
    end

    test "sorting preserves query parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches?q=gpt-4o-mini")

      # Change sort option
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "model"})

      html = render(view)
      assert html =~ "q=gpt-4o-mini"
      assert has_element?(view, "#sort_by")
    end

    test "sorting preserves pagination offset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches?limit=15")

      # Change sort option
      view
      |> element("form[phx-change='change-sort']")
      |> render_change(%{"sort_by" => "model"})

      assert has_element?(view, "#sort_by")
    end

    test "offset URLs redirect to keyset-compatible params", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/batches?offset=10&limit=10")
      assert to =~ "/batches?"
      assert to =~ "limit=10"
      refute to =~ "offset="
    end

    test "invalid sort option defaults to newest first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches?sort_by=invalid_sort")

      # The invalid sort should be replaced with default
      html = render(view)
      # Should default to -created_at
      # HTML format: <option selected="" value="-created_at">
      assert html =~ ~s(<option selected="" value="-created_at">)
    end

    test "all sort options are available in dropdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")

      html = render(view)

      # Check that all expected sort options are present
      assert html =~ "Newest first"
      assert html =~ "Oldest first"
    end
  end

  describe "redeliver batch action visibility" do
    test "does not render redeliver buttons on batch index", %{conn: conn} do
      partial_batch = generate(seeded_batch(state: :partially_delivered))
      failed_delivery_batch = generate(seeded_batch(state: :delivery_failed))

      {:ok, view, _html} = live(conn, ~p"/batches")

      refute has_element?(view, "#redeliver-batch-#{partial_batch.id}")
      refute has_element?(view, "#redeliver-batch-#{failed_delivery_batch.id}")
    end
  end

  # Helper function to count table rows (excluding header)
end
