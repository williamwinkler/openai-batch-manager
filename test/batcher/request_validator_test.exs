defmodule Batcher.RequestValidatorTest do
  use ExUnit.Case, async: true

  alias Batcher.RequestValidator

  describe "validate_json/1" do
    test "validates valid webhook delivery message" do
      json =
        JSON.encode!(%{
          "custom_id" => "test-123",
          "url" => "/v1/responses",
          "method" => "POST",
          "body" => %{
            "model" => "gpt-4o-mini",
            "input" => "Test input"
          },
          "delivery" => %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert {:ok, validated} = RequestValidator.validate_json(json)
      assert validated.custom_id == "test-123"
      assert validated.url == "/v1/responses"
      assert validated.method == "POST"
      assert validated.body.model == "gpt-4o-mini"
      assert validated.delivery.type == "webhook"
      assert validated.delivery.webhook_url == "https://example.com/webhook"
    end

    test "validates valid RabbitMQ delivery message" do
      json =
        JSON.encode!(%{
          "custom_id" => "rabbitmq-test",
          "url" => "/v1/responses",
          "method" => "POST",
          "body" => %{
            "model" => "gpt-4o-mini",
            "input" => "Test input"
          },
          "delivery" => %{
            "type" => "rabbitmq",
            "rabbitmq_exchange" => "batching.results",
            "rabbitmq_queue" => "results_queue"
          }
        })

      assert {:ok, validated} = RequestValidator.validate_json(json)
      assert validated.custom_id == "rabbitmq-test"
      assert validated.delivery.type == "rabbitmq"
      assert validated.delivery.rabbitmq_queue == "results_queue"
      assert validated.delivery.rabbitmq_exchange == "batching.results"
    end

    test "returns error for invalid JSON string" do
      invalid_json = "{invalid json}"

      assert {:error, {:invalid_json, _}} = RequestValidator.validate_json(invalid_json)
    end

    test "returns error for missing required fields" do
      json =
        JSON.encode!(%{
          "custom_id" => "test"
          # Missing url, method, body, delivery
        })

      assert {:error, {:validation_failed, _errors}} = RequestValidator.validate_json(json)
    end

    test "returns error for invalid url enum value" do
      json =
        JSON.encode!(%{
          "custom_id" => "test-123",
          "url" => "/v1/invalid",
          "method" => "POST",
          "body" => %{
            "model" => "gpt-4o-mini",
            "input" => "Test"
          },
          "delivery" => %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert {:error, {:validation_failed, _errors}} = RequestValidator.validate_json(json)
    end

    test "returns error for missing model in body" do
      json =
        JSON.encode!(%{
          "custom_id" => "test-123",
          "url" => "/v1/responses",
          "method" => "POST",
          "body" => %{
            "input" => "Test"
            # Missing model
          },
          "delivery" => %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert {:error, {:validation_failed, _errors}} = RequestValidator.validate_json(json)
    end

    test "returns error for invalid delivery config - missing webhook_url" do
      json =
        JSON.encode!(%{
          "custom_id" => "test-123",
          "url" => "/v1/responses",
          "method" => "POST",
          "body" => %{
            "model" => "gpt-4o-mini",
            "input" => "Test"
          },
          "delivery" => %{
            "type" => "webhook"
            # Missing webhook_url
          }
        })

      assert {:error, {:validation_failed, _errors}} = RequestValidator.validate_json(json)
    end

    test "converts string keys to atoms" do
      json =
        JSON.encode!(%{
          "custom_id" => "test-123",
          "url" => "/v1/responses",
          "method" => "POST",
          "body" => %{
            "model" => "gpt-4o-mini",
            "input" => "Test"
          },
          "delivery" => %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert {:ok, validated} = RequestValidator.validate_json(json)
      # Verify keys are atoms (not strings)
      assert Map.has_key?(validated, :custom_id)
      assert Map.has_key?(validated, :url)
      assert Map.has_key?(validated, :body)
      assert Map.has_key?(validated, :delivery)
      # Verify nested maps also have atom keys
      assert Map.has_key?(validated.body, :model)
      assert Map.has_key?(validated.delivery, :type)
    end

    test "validates different endpoint types" do
      endpoints = [
        "/v1/responses",
        "/v1/chat/completions",
        "/v1/completions",
        "/v1/embeddings",
        "/v1/moderations"
      ]

      for url <- endpoints do
        json =
          JSON.encode!(%{
            "custom_id" => "test-#{url}",
            "url" => url,
            "method" => "POST",
            "body" => %{
              "model" => "gpt-4o-mini",
              "input" => "Test"
            },
            "delivery" => %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })

        assert {:ok, validated} = RequestValidator.validate_json(json)
        assert validated.url == url
      end
    end
  end

  describe "validate/1" do
    test "validates map data directly" do
      data = %{
        "custom_id" => "test-123",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "Test"
        },
        "delivery" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      assert {:ok, validated} = RequestValidator.validate(data)
      assert validated.custom_id == "test-123"
    end

    test "returns error for invalid map data" do
      data = %{
        "custom_id" => "test"
        # Missing required fields
      }

      assert {:error, {:validation_failed, _errors}} = RequestValidator.validate(data)
    end
  end
end
