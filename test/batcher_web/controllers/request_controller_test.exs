defmodule BatcherWeb.RequestControllerTest do
  use BatcherWeb.ConnCase, async: false

  alias Batcher.Batching

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

    test "returns 500 for rabbitmq with neither queue nor exchange (Ash validation)", %{conn: conn} do
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
          # Delete the batch while BatchBuilder is still running
          # This will cause get_batch_by_id to fail in BatchBuilder.handle_call
          # which will return {:error, error}, triggering the generic error handler
          Ash.destroy!(batch)

          # Now try to add a request - BatchBuilder should fail to get the batch
          # and return {:error, error}, which RequestHandler wraps as {:error, {:batch_assignment_error, ...}}
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

          # Try to add request - BatchBuilder should fail because batch doesn't exist
          conn2 = post(conn, ~p"/api/requests", request_body)

          # Should return 500 with generic error message
          assert response(conn2, 500)
          body = JSON.decode!(conn2.resp_body)
          assert body["errors"]
          error = hd(body["errors"])
          assert error["code"] == "internal_error"
          assert error["title"] == "Internal Server Error"
          # Should not leak internal error details
          refute String.contains?(error["detail"], "batch_assignment_error")

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
end
