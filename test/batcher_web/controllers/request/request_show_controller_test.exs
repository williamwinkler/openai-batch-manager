defmodule BatcherWeb.RequestShowControllerTest do
  use BatcherWeb.ConnCase, async: false

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

  describe "GET /api/requests/:custom_id" do
    test "returns request by custom_id including delivery_attempt history", %{conn: conn} do
      batch =
        seeded_batch(state: :delivering, model: "gpt-4o-mini", url: "/v1/responses")
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          custom_id: "lookup_req_1",
          state: :delivery_failed,
          model: "gpt-4o-mini",
          url: "/v1/responses",
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        )
        |> generate()

      Ash.create!(Batcher.Batching.RequestDeliveryAttempt, %{
        request_id: request.id,
        delivery_config: request.delivery_config,
        outcome: :timeout,
        error_msg: "request timed out"
      })

      conn = get(conn, ~p"/api/requests/#{request.custom_id}")
      assert response(conn, 200)

      body = JSON.decode!(conn.resp_body)
      assert body["id"] == request.id
      assert body["custom_id"] == request.custom_id
      assert body["state"] == "delivery_failed"
      assert is_list(body["delivery_attempts"])
      assert length(body["delivery_attempts"]) == 1

      attempt = hd(body["delivery_attempts"])
      assert attempt["outcome"] == "timeout"
      assert attempt["error_msg"] == "request timed out"
    end

    test "returns 404 when custom_id does not exist", %{conn: conn} do
      conn = get(conn, ~p"/api/requests/does_not_exist")
      assert response(conn, 404)
    end
  end
end
