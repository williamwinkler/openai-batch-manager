defmodule BatcherWeb.RequestRedeliverControllerTest do
  use BatcherWeb.ConnCase, async: false

  alias Batcher.Batching
  import Batcher.Generator

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))

    # Clear any existing BatchBuilders to avoid stale state from previous tests
    for {url, model} <- [{"/v1/responses", "gpt-4o-mini"}] do
      case Registry.lookup(Batcher.Batching.Registry, {url, model}) do
        [{pid, _}] ->
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            100 -> :ok
          end

        [] ->
          :ok
      end
    end

    {:ok, server: server}
  end

  describe "POST /api/requests/:custom_id/redeliver" do
    test "triggers redelivery when request is in a retryable state", %{conn: conn} do
      batch =
        seeded_batch(state: :partially_delivered, model: "gpt-4o-mini", url: "/v1/responses")
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          custom_id: "redeliver_req_1",
          state: :delivery_failed,
          response_payload: %{"output" => "response"},
          model: "gpt-4o-mini",
          url: "/v1/responses"
        )
        |> generate()

      conn = post(conn, ~p"/api/requests/#{request.custom_id}/redeliver")
      assert response(conn, 202)

      body = JSON.decode!(conn.resp_body)
      assert body["custom_id"] == request.custom_id
      assert body["state"] == "openai_processed"
      assert body["message"] == "Redelivery triggered"

      batch_after = Batching.get_batch_by_id!(batch.id)
      assert batch_after.state == :partially_delivered
    end

    test "returns 422 when request is not in a retryable state", %{conn: conn} do
      batch =
        seeded_batch(state: :ready_to_deliver, model: "gpt-4o-mini", url: "/v1/responses")
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          custom_id: "redeliver_req_invalid",
          state: :pending,
          model: "gpt-4o-mini",
          url: "/v1/responses"
        )
        |> generate()

      conn = post(conn, ~p"/api/requests/#{request.custom_id}/redeliver")
      assert response(conn, 422)

      body = JSON.decode!(conn.resp_body)
      assert body["errors"]
      error = hd(body["errors"])
      assert error["code"] == "invalid_state"
    end

    test "triggers redelivery when batch is ready_to_deliver", %{conn: conn} do
      batch =
        seeded_batch(state: :ready_to_deliver, model: "gpt-4o-mini", url: "/v1/responses")
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          custom_id: "redeliver_req_ready",
          state: :delivery_failed,
          model: "gpt-4o-mini",
          url: "/v1/responses",
          response_payload: %{"output" => "response"}
        )
        |> generate()

      conn = post(conn, ~p"/api/requests/#{request.custom_id}/redeliver")
      assert response(conn, 202)

      body = JSON.decode!(conn.resp_body)
      assert body["custom_id"] == request.custom_id
      assert body["state"] == "openai_processed"
      assert body["message"] == "Redelivery triggered"
    end

    test "returns 422 when batch is currently delivering", %{conn: conn} do
      batch =
        seeded_batch(state: :delivering, model: "gpt-4o-mini", url: "/v1/responses")
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          custom_id: "redeliver_req_invalid_batch",
          state: :delivery_failed,
          response_payload: %{"output" => "response"},
          model: "gpt-4o-mini",
          url: "/v1/responses"
        )
        |> generate()

      conn = post(conn, ~p"/api/requests/#{request.custom_id}/redeliver")
      assert response(conn, 422)

      body = JSON.decode!(conn.resp_body)
      assert body["errors"]
      error = hd(body["errors"])
      assert error["code"] == "invalid_batch_state"
      assert error["detail"] == "Batch cannot redeliver while it is currently delivering"
    end

    test "returns 404 when custom_id does not exist", %{conn: conn} do
      conn = post(conn, ~p"/api/requests/does_not_exist/redeliver")
      assert response(conn, 404)
    end
  end
end
