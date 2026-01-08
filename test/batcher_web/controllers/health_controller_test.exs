defmodule BatcherWeb.HealthControllerTest do
  use BatcherWeb.ConnCase, async: true

  test "GET /health returns 200 OK with status", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert response(conn, 200) == ~s({"status":"ok"})
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end
end
