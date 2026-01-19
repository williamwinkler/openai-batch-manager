defmodule BatcherWeb.PageControllerTest do
  use BatcherWeb.ConnCase

  test "GET / renders BatchIndexLive", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    # Verify it renders the BatchIndexLive page
    assert html =~ "Batches"
    assert html =~ "Batch Manager"
    # Verify it's a LiveView (has phx-main attribute)
    assert html =~ "data-phx-main"
  end
end
