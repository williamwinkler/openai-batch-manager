defmodule BatcherWeb.HomeLiveTest do
  use BatcherWeb.LiveViewCase, async: true

  describe "home page" do
    test "renders with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "OpenAI Batch Manager"
    end

    test "has navigation link to batches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a[href="/batches"]|)
      assert render(view) =~ "Batches"
    end

    test "has navigation link to requests", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a[href="/requests"]|)
      assert render(view) =~ "Requests"
    end

    test "developer tool links open in new tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a[href="/api/swaggerui"][target="_blank"]|)
      assert has_element?(view, ~s|a[href="/api/openapi"][target="_blank"]|)
    end
  end
end
