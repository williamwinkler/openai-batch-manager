defmodule Batcher.OpenaiApiClientTest do
  use ExUnit.Case, async: true

  alias Batcher.OpenaiApiClient

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "Batcher.OpenaiApiClient.upload_file/1" do
    test "successfully upload file", %{server: server} do
      response = %{
        "bytes" => 718,
        "created_at" => 1766068446,
        "expires_at" => 1768660446,
        "filename" => "batch.jsonl",
        "id" => "file-1quwTNE3rPZezkuRuGuXaS",
        "object" => "file",
        "purpose" => "batch",
        "status" => "processed",
        "status_details" => nil
      }

      TestServer.add(server, "/v1/files",
        via: :post,
        to: fn conn ->
          assert {"authorization", "Bearer sk-test-dummy-key"} in conn.req_headers
          assert {"content-type", content_type} = List.keyfind(conn.req_headers, "content-type", 0)
          assert content_type =~ "multipart/form-data"

          {:ok, body, conn} = Plug.Conn.read_body(conn)

          # Verify purpose field is "batch"
          assert body =~ ~s(name="purpose")
          assert body =~ "batch"

          # Verify file field exists
          assert body =~ ~s(name="file")
          assert body =~ "batch.jsonl"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, JSON.encode!(response))
        end
      )

      file_path = "test/data/batch.jsonl"

      result = OpenaiApiClient.upload_file(file_path)
      assert {:ok, body} = result
      assert body["id"] == "file-1quwTNE3rPZezkuRuGuXaS"
      assert body["bytes"] == 718
      assert body["status"] == "processed"
    end
  end

  describe "Batcher.OpenaiApiClient.retrieve_file/1" do
    test "successfully retrieve file", %{server: server} do
      file_id = "file-1quwTNE3rPZezkuRuGuXaS"

      response = %{
        "bytes" => 718,
        "created_at" => 1766068446,
        "expires_at" => 1768660446,
        "filename" => "batch.jsonl",
        "id" => file_id,
        "object" => "file",
        "purpose" => "batch",
        "status" => "processed",
        "status_details" => nil
      }

      expect_json_response(server, :get, "/v1/files/#{file_id}", response, 200)

      result = OpenaiApiClient.retrieve_file(file_id)
      assert {:ok, body} = result
      assert body["id"] == file_id
    end

    test "non-existing file_id returns :not_found", %{server: server} do
      file_id = "file-1quwTNE3rPZezkuRuGuXaS"

      response = %{
        "error" => %{
          "code" => nil,
          "message" => "No such File object: file-1quwTNE3rPZezkuRuGuXaA",
          "param" => "id",
          "type" => "invalid_request_error"
        }
      }

      expect_json_response(server, :get, "/v1/files/#{file_id}", response, 404)

      result = OpenaiApiClient.retrieve_file(file_id)
      assert {:error, :not_found} = result
    end
  end

  describe "Batcher.OpenaiApiClient.delete_file/1" do
    test "successfully delete file", %{server: server} do
       file_id = "file-1quwTNE3rPZezkuRuGuXaS"

       response = %{
         "error" => %{
           "code" => nil,
           "message" => "No such File object: file-1quwTNE3rPZezkuRuGuXaS",
           "param" => "id",
           "type" => "invalid_request_error"
         }
       }

       expect_json_response(server, :delete, "/v1/files/#{file_id}", response, 404)

       result = OpenaiApiClient.delete_file(file_id)
       assert {:error, :not_found} = result
    end

    test "deleting non-existing file returns :not_found", %{server: server} do
       file_id = "file-1quwTNE3rPZezkuRuGuXaS"

       response = %{"deleted" => true, "id" => "file-1quwTNE3rPZezkuRuGuXaS", "object" => "file"}

       expect_json_response(server, :delete, "/v1/files/#{file_id}", response, 200)

       result = OpenaiApiClient.delete_file(file_id)
       assert {:ok, body} = result
       assert body["deleted"] == true
    end
  end

  describe "Batcher.OpenaiApiClient.create_batch/3" do
    test "successfully create batch for endpoint: /v1/responses", %{server: server} do
      input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"
      endpoint = "/v1/responses"

      response = %{
        "cancelled_at" => nil,
        "cancelling_at" => nil,
        "completed_at" => nil,
        "completion_window" => "24h",
        "created_at" => 1766073619,
        "endpoint" => "/v1/responses",
        "error_file_id" => nil,
        "errors" => nil,
        "expired_at" => nil,
        "expires_at" => 1766160019,
        "failed_at" => nil,
        "finalizing_at" => nil,
        "id" => "batch_69442513cdb08190bc6dbfdfcd2b9b46",
        "in_progress_at" => nil,
        "input_file_id" => "file-8VY1squavWFjVRZiLRwmHk",
        "metadata" => nil,
        "model" => nil,
        "object" => "batch",
        "output_file_id" => nil,
        "request_counts" => %{"completed" => 0, "failed" => 0, "total" => 0},
        "status" => "validating",
        "usage" => %{
          "input_tokens" => 0,
          "input_tokens_details" => %{"cached_tokens" => 0},
          "output_tokens" => 0,
          "output_tokens_details" => %{"reasoning_tokens" => 0},
          "total_tokens" => 0
        }
      }

      expect_json_response(server, :post, "/v1/batches", response, 200)

      result = OpenaiApiClient.create_batch(input_file_id, endpoint)
      assert {:ok, body} = result
      assert body["status"] == "validating"
      assert body["id"] == response["id"]
      assert body["endpoint"] == endpoint
    end

    test "successfully create batch for endpoint: /v1/chat/completions", %{server: server} do
      input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"
      endpoint = "/v1/chat/completions"

      response = %{
        "cancelled_at" => nil,
        "cancelling_at" => nil,
        "completed_at" => nil,
        "completion_window" => "24h",
        "created_at" => 1766074543,
        "endpoint" => "/v1/chat/completions",
        "error_file_id" => nil,
        "errors" => nil,
        "expired_at" => nil,
        "expires_at" => 1766160943,
        "failed_at" => nil,
        "finalizing_at" => nil,
        "id" => "batch_694428afe97881908c05f24bc9d2d6be",
        "in_progress_at" => nil,
        "input_file_id" => "file-8VY1squavWFjVRZiLRwmHd",
        "metadata" => nil,
        "model" => nil,
        "object" => "batch",
        "output_file_id" => nil,
        "request_counts" => %{"completed" => 0, "failed" => 0, "total" => 0},
        "status" => "validating",
        "usage" => %{
          "input_tokens" => 0,
          "input_tokens_details" => %{"cached_tokens" => 0},
          "output_tokens" => 0,
          "output_tokens_details" => %{"reasoning_tokens" => 0},
          "total_tokens" => 0
        }
      }

      expect_json_response(server, :post, "/v1/batches", response, 200)

      result = OpenaiApiClient.create_batch(input_file_id, endpoint)
      assert {:ok, body} = result
      assert body["status"] == "validating"
      assert body["id"] == response["id"]
      assert body["endpoint"] == endpoint
    end

    test "successfully create batch for endpoint: /v1/embeddings", %{server: server} do
      input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"
      endpoint = "/v1/embeddings"

      response = %{
        "cancelled_at" => nil,
        "cancelling_at" => nil,
        "completed_at" => nil,
        "completion_window" => "24h",
        "created_at" => 1766074894,
        "endpoint" => "/v1/embeddings",
        "error_file_id" => nil,
        "errors" => nil,
        "expired_at" => nil,
        "expires_at" => 1766161294,
        "failed_at" => nil,
        "finalizing_at" => nil,
        "id" => "batch_69442a0e38ac8190becb33b799017d5d",
        "in_progress_at" => nil,
        "input_file_id" => "file-8VY1squavWFjVRZiLRwmHd",
        "metadata" => nil,
        "model" => nil,
        "object" => "batch",
        "output_file_id" => nil,
        "request_counts" => %{"completed" => 0, "failed" => 0, "total" => 0},
        "status" => "validating",
        "usage" => %{
          "input_tokens" => 0,
          "input_tokens_details" => %{"cached_tokens" => 0},
          "output_tokens" => 0,
          "output_tokens_details" => %{"reasoning_tokens" => 0},
          "total_tokens" => 0
        }
      }

      expect_json_response(server, :post, "/v1/batches", response, 200)

      result = OpenaiApiClient.create_batch(input_file_id, endpoint)
      assert {:ok, body} = result
      assert body["status"] == "validating"
      assert body["id"] == response["id"]
      assert body["endpoint"] == endpoint
    end

    test "successfully create batch for endpoint: /v1/completions", %{server: server} do
      input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"
      endpoint = "/v1/completions"

      response = %{
        "cancelled_at" => nil,
        "cancelling_at" => nil,
        "completed_at" => nil,
        "completion_window" => "24h",
        "created_at" => 1766074998,
        "endpoint" => "/v1/completions",
        "error_file_id" => nil,
        "errors" => nil,
        "expired_at" => nil,
        "expires_at" => 1766161398,
        "failed_at" => nil,
        "finalizing_at" => nil,
        "id" => "batch_69442a76eb588190b6d0bd71b234657a",
        "in_progress_at" => nil,
        "input_file_id" => "file-8VY1squavWFjVRZiLRwmHd",
        "metadata" => nil,
        "model" => nil,
        "object" => "batch",
        "output_file_id" => nil,
        "request_counts" => %{"completed" => 0, "failed" => 0, "total" => 0},
        "status" => "validating",
        "usage" => %{
          "input_tokens" => 0,
          "input_tokens_details" => %{"cached_tokens" => 0},
          "output_tokens" => 0,
          "output_tokens_details" => %{"reasoning_tokens" => 0},
          "total_tokens" => 0
        }
      }

      expect_json_response(server, :post, "/v1/batches", response, 200)

      result = OpenaiApiClient.create_batch(input_file_id, endpoint)
      assert {:ok, body} = result
      assert body["status"] == "validating"
      assert body["id"] == response["id"]
      assert body["endpoint"] == endpoint
    end

    test "returns :bad_request for invalid endpoint", %{server: server} do
      input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"
      endpoint = "/v1/invalid"

      response = %{
        "error" => %{
          "code" => "invalid_value",
          "message" => "Invalid value: '/v1/invalid'. Supported values are: '/v1/chat/completions', '/v1/completions', '/v1/embeddings', '/v1/responses', and '/v1/moderations'.",
          "param" => "endpoint",
          "type" => "invalid_request_error"
        }
      }

      expect_json_response(server, :post, "/v1/batches", response, 400)

      result = OpenaiApiClient.create_batch(input_file_id, endpoint)
      assert {:error, {:bad_request, _}} = result
    end
    test "successfully create batch for endpoint: /v1/moderations", %{server: server} do
      input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"
      endpoint = "/v1/moderations"

      response = %{
        "cancelled_at" => nil,
        "cancelling_at" => nil,
        "completed_at" => nil,
        "completion_window" => "24h",
        "created_at" => 1766075050,
        "endpoint" => "/v1/moderations",
        "error_file_id" => nil,
        "errors" => nil,
        "expired_at" => nil,
        "expires_at" => 1766161450,
        "failed_at" => nil,
        "finalizing_at" => nil,
        "id" => "batch_69442aaa4e2c8190bd5a751702db5be6",
        "in_progress_at" => nil,
        "input_file_id" => "file-8VY1squavWFjVRZiLRwmHd",
        "metadata" => nil,
        "model" => nil,
        "object" => "batch",
        "output_file_id" => nil,
        "request_counts" => %{"completed" => 0, "failed" => 0, "total" => 0},
        "status" => "validating",
        "usage" => %{
          "input_tokens" => 0,
          "input_tokens_details" => %{"cached_tokens" => 0},
          "output_tokens" => 0,
          "output_tokens_details" => %{"reasoning_tokens" => 0},
          "total_tokens" => 0
        }
      }

      expect_json_response(server, :post, "/v1/batches", response, 200)

      result = OpenaiApiClient.create_batch(input_file_id, endpoint)
      assert {:ok, body} = result
      assert body["status"] == "validating"
      assert body["id"] == response["id"]
      assert body["endpoint"] == endpoint
    end
  end

  describe "Batcher.OpenaiApiClient.cancel_batch/1" do
    test "successfully cancel batch", %{server: server} do
      batch_id = generate_batch_id()

      response = %{
        "cancelled_at" => nil,
        "cancelling_at" => 1766075379,
        "completed_at" => nil,
        "completion_window" => "24h",
        "created_at" => 1766073619,
        "endpoint" => "/v1/responses",
        "error_file_id" => nil,
        "errors" => nil,
        "expired_at" => nil,
        "expires_at" => 1766160019,
        "failed_at" => nil,
        "finalizing_at" => nil,
        "id" => batch_id,
        "in_progress_at" => 1766073682,
        "input_file_id" => "file-8VY1squavWFjVRZiLRwmHk",
        "metadata" => nil,
        "model" => "gpt-4o-mini-2024-07-18",
        "object" => "batch",
        "output_file_id" => nil,
        "request_counts" => %{"completed" => 0, "failed" => 0, "total" => 2},
        "status" => "cancelling",
        "usage" => %{
          "input_tokens" => 0,
          "input_tokens_details" => %{"cached_tokens" => 0},
          "output_tokens" => 0,
          "output_tokens_details" => %{"reasoning_tokens" => 0},
          "total_tokens" => 0
        }
      }

      expect_json_response(server, :post, "/v1/batches/#{batch_id}/cancel", response, 200)

      result = OpenaiApiClient.cancel_batch(batch_id)
      assert {:ok, body} = result
      assert body["status"] == "cancelling"
      assert body["id"] == batch_id
    end

    test "returns :not_found when batch does not exist", %{server: server} do
      batch_id = generate_batch_id()

      response = %{
        "error" => %{
          "code" => nil,
          "message" => "No batch found with id 'batch_69442513cdb08190bc6dbfdfcd2b9b45'.",
          "param" => nil,
          "type" => "invalid_request_error"
        }
      }

      expect_json_response(server, :post, "/v1/batches/#{batch_id}/cancel", response, 404)

      result = OpenaiApiClient.cancel_batch(batch_id)
      assert {:error, :not_found} = result
    end

    test "returns :bad_request when batch id is invalid", %{server: server} do
      batch_id = "invalid"

      response = %{
        "error" => %{
          "code" => "invalid_value",
          "message" => "Invalid 'batch_id': '#{batch_id}'. Expected an ID that begins with 'batch'.",
          "param" => "batch_id",
          "type" => "invalid_request_error"
        }
      }

      expect_json_response(server, :post, "/v1/batches/#{batch_id}/cancel", response, 400)

      result = OpenaiApiClient.cancel_batch(batch_id)
      assert {:error, {:bad_request, _}} = result
    end
  end

  describe "Batcher.OpenaiApiClient.check_batch_status/1" do
    test "returns response object on success", %{server: server} do
      batch_id = generate_batch_id()

      response = %{
        "cancelled_at" => nil,
        "cancelling_at" => nil,
        "completed_at" => 1_764_436_320,
        "completion_window" => "24h",
        "created_at" => 1_764_435_445,
        "endpoint" => "/v1/responses",
        "error_file_id" => nil,
        "errors" => nil,
        "expired_at" => nil,
        "expires_at" => 1_764_521_845,
        "failed_at" => nil,
        "finalizing_at" => 1_764_436_318,
        "id" => batch_id,
        "in_progress_at" => 1_764_435_508,
        "input_file_id" => "file-AaTNMrNv4BRVQyzmXqkg31",
        "metadata" => nil,
        "model" => "gpt-4o-mini-2024-07-18",
        "object" => "batch",
        "output_file_id" => "file-C972wfTZyRZSo9RPxxAGgv",
        "request_counts" => %{"completed" => 5, "failed" => 0, "total" => 5},
        "status" => "completed",
        "usage" => %{
          "input_tokens" => 115,
          "input_tokens_details" => %{"cached_tokens" => 0},
          "output_tokens" => 10,
          "output_tokens_details" => %{"reasoning_tokens" => 0},
          "total_tokens" => 125
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{batch_id}", response, 200)

      result = OpenaiApiClient.check_batch_status(batch_id)
      assert {:ok, body} = result
      assert body["id"] == batch_id
      assert body["status"] == "completed"
    end

    test "returns an :not_found for non existing batch id", %{server: server} do
      batch_id = generate_batch_id()

      response = %{
        "error" => %{
          "code" => nil,
          "message" => "No batch found with id '#{batch_id}'.",
          "param" => nil,
          "type" => "invalid_request_error"
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{batch_id}", response, 404)

      result = OpenaiApiClient.check_batch_status(batch_id)
      assert {:error, :not_found} == result
    end

    test "without authorization", %{server: server} do
      batch_id = generate_batch_id()

      response = %{
        "error" => %{
          "code" => nil,
          "message" => "Missing bearer or basic authentication in header",
          "param" => nil,
          "type" => "invalid_request_error"
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{batch_id}", response, 401)

      result = OpenaiApiClient.check_batch_status(batch_id)
      assert {:error, :unauthorized} == result
    end
  end

  describe "Batcher.OpenaiApiClient.extract_token_usage_from_batch_status/1" do
    test "extract tokens from usage" do
      batch_response = %{
        "usage" => %{
          "input_tokens" => 115,
          "input_tokens_details" => %{"cached_tokens" => 50},
          "output_tokens" => 1000,
          "output_tokens_details" => %{"reasoning_tokens" => 600},
          "total_tokens" => 1115
        }
      }

    usage = OpenaiApiClient.extract_token_usage_from_batch_status(batch_response)

    assert usage.input_tokens == 115
    assert usage.cached_tokens == 50
    assert usage.reasoning_tokens == 600
    assert usage.output_tokens == 1000
    end
  end

  defp expect_json_response(server, method, path, body_map, status) do
    TestServer.add(server, path,
      via: method,
      to: fn conn ->
        assert {"authorization", "Bearer sk-test-dummy-key"} in conn.req_headers

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, JSON.encode!(body_map))
      end
    )
  end

  defp generate_batch_id do
    random_part = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "batch_" <> random_part
  end
end
