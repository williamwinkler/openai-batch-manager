defmodule BatcherWeb.BatchIndexPaginationReloadLiveTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Batching
  alias BatcherWeb.Live.Utils.ActionActivity

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

  describe "pagination" do
    test "displays pagination controls with page numbers", %{conn: conn} do
      # Use a small limit to ensure multiple pages
      {:ok, view, _html} = live(conn, ~p"/batches?limit=10")

      wait_for(fn -> has_element?(view, ".join") end)
      assert has_element?(view, ".join")
    end

    test "shows total count once available", %{conn: conn} do
      {:ok, view, initial_html} = live(conn, ~p"/batches")

      assert initial_html =~ "Calculating..." or initial_html =~ "of 20"
      wait_for(fn -> render(view) =~ "of 20" end)
      html = render(view)
      assert html =~ "of 20"
    end

    test "navigation buttons are disabled on first page", %{conn: conn} do
      # Use a small limit to ensure we have multiple pages and navigation buttons
      {:ok, view, _html} = live(conn, ~p"/batches?limit=10")

      html = render(view)
      assert html =~ "Previous"
      assert html =~ "btn-disabled"
    end

    test "clicking next navigates forward", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches?limit=10")
      first_before = render(view) |> first_batch_row_id()

      view
      |> element("a.join-item", "Next")
      |> render_click()

      wait_for(fn -> render(view) |> first_batch_row_id() != first_before end)

      new_batches = view |> element("#batches") |> render() |> count_table_rows()
      assert new_batches > 0
    end

    test "previous button works after moving forward", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches?limit=10")
      first_page_first_id = render(view) |> first_batch_row_id()

      view
      |> element("a.join-item", "Next")
      |> render_click()

      wait_for(fn -> render(view) |> first_batch_row_id() != first_page_first_id end)

      # Should be back on page 1
      view
      |> element("a.join-item", "Previous")
      |> render_click()

      wait_for(fn -> render(view) |> first_batch_row_id() == first_page_first_id end)

      html = render(view)
      assert html =~ "Previous"
      assert html =~ "btn-disabled"
    end

    test "next button is disabled on last page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches?limit=10")
      view |> element("a.join-item", "Next") |> render_click()
      html = render(view)
      assert html =~ "Next"
      assert html =~ "btn-disabled"
    end

    test "pagination preserves query text parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches?q=gpt-4o-mini&limit=10")

      # Check that page links contain the query parameter
      html = render(view)
      assert html =~ "q=gpt-4o-mini"
    end

    test "pagination preserves sort_by parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches?sort_by=model&limit=10")

      assert has_element?(view, "#sort_by")
    end

    test "pagination preserves both query and sort_by parameters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches?q=gpt-4o-mini&sort_by=-created_at&limit=10")

      # Check that page links contain both parameters
      html = render(view)
      assert html =~ "q=gpt-4o-mini"
      assert html =~ "sort_by=-created_at"
    end

    test "pagination shows 0 items when empty", %{conn: conn} do
      # Clear all batches
      {:ok, batches} = Batching.list_batches()
      Enum.each(batches, fn batch -> Batching.destroy_batch(batch) end)

      {:ok, view, _html} = live(conn, ~p"/batches")

      # Should show "0 items"
      html = render(view)
      assert html =~ "No batches found"
    end

    test "pubsub row reload does not reset count to loading state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")
      wait_for(fn -> render(view) =~ "of 20" end)

      BatcherWeb.Endpoint.broadcast("batches:created", "created", %{data: %{id: -1}})

      :timer.sleep(75)
      html = render(view)
      refute html =~ "Calculating..."
      assert html =~ "of 20"
    end

    test "coalesces burst lifecycle events and remains stable", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/batches")
      wait_for(fn -> render(view) =~ "of 20" end)

      for _ <- 1..8 do
        BatcherWeb.Endpoint.broadcast("batches:created", "created", %{data: %{id: -1}})
      end

      :timer.sleep(80)
      html = render(view)
      refute html =~ "Calculating..."
      assert html =~ "of 20"
    end

    test "ignores off-page state change events", %{conn: conn, batches: batches} do
      {:ok, view, _html} = live(conn, ~p"/batches?limit=10")
      first_before = render(view) |> first_batch_row_id()

      off_page_batch =
        batches
        |> Enum.sort_by(& &1.id, :desc)
        |> Enum.at(15)

      BatcherWeb.Endpoint.broadcast(
        "batches:state_changed:#{off_page_batch.id}",
        "state_changed",
        %{data: off_page_batch}
      )

      :timer.sleep(120)
      assert first_batch_row_id(render(view)) == first_before
    end

    test "reloads on batches:created only on first-page newest empty query", %{conn: conn} do
      {:ok, first_page_view, _html} = live(conn, ~p"/batches")
      first_before = render(first_page_view) |> first_batch_row_id()

      {:ok, next_page_view, _html} = live(conn, ~p"/batches?limit=10")

      next_page_view
      |> element("a.join-item", "Next")
      |> render_click()

      second_page_before = render(next_page_view) |> first_batch_row_id()

      {:ok, _batch} = Batching.create_batch("new-top-feed-model", "/v1/responses")

      wait_for(fn -> render(first_page_view) |> first_batch_row_id() != first_before end)

      :timer.sleep(120)
      assert first_batch_row_id(render(next_page_view)) == second_page_before
    end

    test "single-flight backpressure schedules one follow-up reload", %{conn: conn} do
      Application.put_env(:batcher, :batch_index_reload_delay_ms, 180)

      {:ok, view, _html} = live(conn, ~p"/batches")
      wait_for(fn -> render(view) =~ "of 20" end)

      for _ <- 1..5 do
        BatcherWeb.Endpoint.broadcast("batches:created", "created", %{data: %{id: -1}})
      end

      :timer.sleep(300)
      html = render(view)
      refute html =~ "Calculating..."
      assert html =~ "of 20"
    end

    test "shared action activity loading propagates across index and show views", %{
      conn: conn,
      batches: batches
    } do
      batch = List.first(batches)
      key = {:batch_action, :cancel, batch.id}

      {:ok, index_view, _html} = live(conn, ~p"/batches?limit=25")
      {:ok, show_view, _html} = live(conn, ~p"/batches/#{batch.id}")

      :ok = ActionActivity.start(key, scope: {:batch, batch.id}, ttl_ms: 2_000)
      assert ActionActivity.active?(key)

      wait_for(fn ->
        render(index_view) =~ ~s(id="cancel-batch-#{batch.id}") and
          render(index_view) =~ "disabled"
      end)

      wait_for(fn ->
        render(show_view) =~ ~s(id="cancel-batch") and render(show_view) =~ "disabled"
      end)

      :ok = ActionActivity.finish(key, scope: {:batch, batch.id})

      wait_for(fn ->
        not String.contains?(render(index_view), ~s(id="cancel-batch-#{batch.id}" disabled))
      end)
    end
  end

  defp count_table_rows(html) do
    # Count <tr> elements that are not in <thead>
    html
    |> String.split("<tr")
    |> length()
    # Subtract 1 for the opening tag split
    |> Kernel.-(1)
  end

  defp first_batch_row_id(html) do
    case Regex.run(~r/id=\"batch-created-(\d+)\"/, html) do
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
