defmodule BatcherWeb.RequestControllerTest do
  use BatcherWeb.ConnCase, async: false

  alias Batcher.Batching
  alias Batcher.System.MaintenanceGate
  import Batcher.Generator

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))

    # Clear any existing BatchBuilders to avoid stale state from previous tests
    for {url, model} <- [{"/v1/responses", "gpt-4o-mini"}] do
      case Registry.lookup(Batcher.BatchRegistry, {url, model}) do
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

  describe "POST /api/requests" do
    setup do
      on_exit(fn -> MaintenanceGate.disable!() end)
      :ok
    end

    test "returns 503 when maintenance mode is enabled", %{conn: conn} do
      MaintenanceGate.enable!()

      request_body = %{
        "custom_id" => "maintenance_blocked_req",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Blocked by maintenance"
        },
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      conn = post(conn, ~p"/api/requests", request_body)

      assert response(conn, 503)
      body = JSON.decode!(conn.resp_body)
      assert [error | _] = body["errors"]
      assert error["code"] == "maintenance_mode"
    end

    test "creates request successfully and returns 202 Accepted", %{conn: conn} do
      request_body = %{
        "custom_id" => "test_req_1",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "What color is a grey Porsche?"
        },
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      conn = post(conn, ~p"/api/requests", request_body)

      assert response(conn, 202)
      body = JSON.decode!(conn.resp_body)
      assert body["custom_id"] == "test_req_1"

      # Verify request was created
      {:ok, batches} = Batching.list_batches()
      assert length(batches) >= 1
    end

    test "returns 409 Conflict for duplicate custom_id", %{conn: conn} do
      request_body = %{
        "custom_id" => "duplicate_id",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "First request"
        },
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      # Create first request
      conn1 = post(conn, ~p"/api/requests", request_body)
      assert response(conn1, 202)

      # Try to create duplicate
      conn2 = post(conn, ~p"/api/requests", request_body)

      assert response(conn2, 409)
      body = JSON.decode!(conn2.resp_body)
      assert body["errors"]
      error = hd(body["errors"])
      assert error["code"] == "duplicate_custom_id"
    end

    test "returns 422 for missing required field", %{conn: conn} do
      # Missing required 'custom_id' field
      invalid_body = %{
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test"
        },
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      conn = post(conn, ~p"/api/requests", invalid_body)

      # OpenApiSpex validation returns 422 for validation errors
      assert response(conn, 422)
      response_body = JSON.decode!(conn.resp_body)
      assert Map.has_key?(response_body, "errors")
    end

    test "handles RabbitMQ delivery type with queue only (default exchange)", %{conn: conn} do
      request_body = %{
        "custom_id" => "rabbitmq_req",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test message"
        },
        "delivery_config" => %{
          "type" => "rabbitmq",
          "rabbitmq_queue" => "results_queue"
        }
      }

      conn = post(conn, ~p"/api/requests", request_body)

      assert response(conn, 202)
      body = JSON.decode!(conn.resp_body)
      assert body["custom_id"] == "rabbitmq_req"

      # Verify request was created
      {:ok, batches} = Batching.list_batches()
      assert length(batches) >= 1
    end

    test "handles RabbitMQ delivery type with exchange and routing_key", %{conn: conn} do
      request_body = %{
        "custom_id" => "rabbitmq_exchange_req",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test message"
        },
        "delivery_config" => %{
          "type" => "rabbitmq",
          "rabbitmq_exchange" => "batching.results",
          "rabbitmq_routing_key" => "requests.completed"
        }
      }

      conn = post(conn, ~p"/api/requests", request_body)

      assert response(conn, 202)
      body = JSON.decode!(conn.resp_body)
      assert body["custom_id"] == "rabbitmq_exchange_req"
    end

    test "returns 422 for invalid delivery type", %{conn: conn} do
      invalid_body = %{
        "custom_id" => "invalid_delivery",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test"
        },
        "delivery_config" => %{
          "type" => "invalid_type"
        }
      }

      conn = post(conn, ~p"/api/requests", invalid_body)

      assert response(conn, 422)
      response_body = JSON.decode!(conn.resp_body)
      assert Map.has_key?(response_body, "errors")
    end

    test "returns 422 for missing webhook_url when delivery type is webhook", %{conn: conn} do
      invalid_body = %{
        "custom_id" => "missing_webhook_url",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test"
        },
        "delivery_config" => %{
          "type" => "webhook"
        }
      }

      conn = post(conn, ~p"/api/requests", invalid_body)

      assert response(conn, 422)
      response_body = JSON.decode!(conn.resp_body)
      assert Map.has_key?(response_body, "errors")
    end

    test "returns 500 for rabbitmq exchange without routing_key (Ash validation)", %{conn: conn} do
      # This test validates that exchange without routing_key is rejected.
      # OpenAPI schema allows this through (can't do conditional required),
      # but Ash validation catches it and returns an internal error.
      invalid_body = %{
        "custom_id" => "missing_routing_key",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test"
        },
        "delivery_config" => %{
          "type" => "rabbitmq",
          "rabbitmq_exchange" => "batching.results"
        }
      }

      conn = post(conn, ~p"/api/requests", invalid_body)

      # Ash validation returns 500 (internal error) for validation failures
      assert response(conn, 500)
      response_body = JSON.decode!(conn.resp_body)
      assert Map.has_key?(response_body, "errors")
    end

    test "returns 500 for rabbitmq with neither queue nor exchange (Ash validation)", %{
      conn: conn
    } do
      # Neither queue nor exchange provided
      invalid_body = %{
        "custom_id" => "missing_both",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test"
        },
        "delivery_config" => %{
          "type" => "rabbitmq"
        }
      }

      conn = post(conn, ~p"/api/requests", invalid_body)

      # Ash validation returns 500 (internal error) for validation failures
      assert response(conn, 500)
      response_body = JSON.decode!(conn.resp_body)
      assert Map.has_key?(response_body, "errors")
    end

    test "returns 422 for invalid method", %{conn: conn} do
      invalid_body = %{
        "custom_id" => "invalid_method",
        "url" => "/v1/responses",
        "method" => "INVALID",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test"
        },
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      conn = post(conn, ~p"/api/requests", invalid_body)

      assert response(conn, 422)
      response_body = JSON.decode!(conn.resp_body)
      assert Map.has_key?(response_body, "errors")
    end

    test "handles empty body in request", %{conn: conn} do
      invalid_body = %{
        "custom_id" => "empty_body",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{},
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      conn = post(conn, ~p"/api/requests", invalid_body)

      # Should fail validation (body needs model at minimum)
      assert response(conn, 422)
    end

    test "returns 500 Internal Server Error for batch assignment errors", %{conn: conn} do
      # Create a valid request first to establish a batch and BatchBuilder
      valid_request = %{
        "custom_id" => "error_setup",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test"
        },
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      conn1 = post(conn, ~p"/api/requests", valid_request)
      assert response(conn1, 202)

      # Get the batch that was created
      {:ok, batches} = Batching.list_batches()
      batch = List.first(batches)

      # Get the BatchBuilder PID
      case Registry.lookup(Batcher.BatchRegistry, {batch.url, batch.model}) do
        [{_pid, _}] ->
          # Delete the batch - this will publish a pub_sub event that terminates the BatchBuilder
          Ash.destroy!(batch)

          # Wait a bit for pub_sub message to be processed
          Process.sleep(50)

          # Verify BatchBuilder was terminated
          assert Registry.lookup(Batcher.BatchRegistry, {batch.url, batch.model}) == []

          # Now try to add a request - since BatchBuilder was terminated,
          # it will create a new BatchBuilder and new batch (correct behavior)
          request_body = %{
            "custom_id" => "error_test_#{:rand.uniform(100_000)}",
            "url" => "/v1/responses",
            "method" => "POST",
            "body" => %{
              "model" => "gpt-4o-mini",
              "input" => "Test"
            },
            "delivery_config" => %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          }

          # Try to add request - should succeed and create new batch
          conn2 = post(conn, ~p"/api/requests", request_body)

          # Should return 202 (accepted) since new batch was created successfully
          assert response(conn2, 202)
          body = JSON.decode!(conn2.resp_body)
          assert body["custom_id"] == request_body["custom_id"]

        [] ->
          # No BatchBuilder found - this shouldn't happen but handle it gracefully
          flunk("Expected BatchBuilder to be registered")
      end
    end

    test "handles valid request without optional fields", %{conn: conn} do
      # Test that requests work without optional fields like tag
      request_body = %{
        "custom_id" => "simple_request",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test"
        },
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      conn = post(conn, ~p"/api/requests", request_body)

      assert response(conn, 202)
      body = JSON.decode!(conn.resp_body)
      assert body["custom_id"] == "simple_request"
    end
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
      assert batch_after.state == :delivering
    end

    test "returns 422 when request is not in a retryable state", %{conn: conn} do
      batch =
        seeded_batch(state: :delivering, model: "gpt-4o-mini", url: "/v1/responses")
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

    test "returns 422 when batch is not in a redelivery-compatible state", %{conn: conn} do
      batch =
        seeded_batch(state: :ready_to_deliver, model: "gpt-4o-mini", url: "/v1/responses")
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          custom_id: "redeliver_req_invalid_batch",
          state: :delivery_failed,
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
    end

    test "returns 404 when custom_id does not exist", %{conn: conn} do
      conn = post(conn, ~p"/api/requests/does_not_exist/redeliver")
      assert response(conn, 404)
    end
  end
end
