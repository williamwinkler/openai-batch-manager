defmodule Batcher.Batching.Validation.RequestValidatorTest do
  use ExUnit.Case, async: true

  alias Batcher.Batching.Validation.RequestValidator

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
          "delivery_config" => %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert {:ok, validated} = RequestValidator.validate_json(json)
      assert validated.custom_id == "test-123"
      assert validated.url == "/v1/responses"
      assert validated.method == "POST"
      assert validated.body.model == "gpt-4o-mini"
      assert validated.delivery_config.type == "webhook"
      assert validated.delivery_config.webhook_url == "https://example.com/webhook"
    end

    test "validates valid RabbitMQ delivery message with queue" do
      json =
        JSON.encode!(%{
          "custom_id" => "rabbitmq-test",
          "url" => "/v1/responses",
          "method" => "POST",
          "body" => %{
            "model" => "gpt-4o-mini",
            "input" => "Test input"
          },
          "delivery_config" => %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "results_queue"
          }
        })

      assert {:ok, validated} = RequestValidator.validate_json(json)
      assert validated.custom_id == "rabbitmq-test"
      assert validated.delivery_config.type == "rabbitmq"
      assert validated.delivery_config.rabbitmq_queue == "results_queue"
    end

    test "returns error for RabbitMQ delivery message with exchange and routing_key" do
      json =
        JSON.encode!(%{
          "custom_id" => "rabbitmq-exchange-test",
          "url" => "/v1/responses",
          "method" => "POST",
          "body" => %{
            "model" => "gpt-4o-mini",
            "input" => "Test input"
          },
          "delivery_config" => %{
            "type" => "rabbitmq",
            "rabbitmq_exchange" => "batching.results",
            "rabbitmq_routing_key" => "requests.completed"
          }
        })

      assert {:error, {:validation_failed, _errors}} = RequestValidator.validate_json(json)
    end

    test "returns error for invalid JSON string" do
      invalid_json = "{invalid json}"

      assert {:error, {:invalid_json, _}} = RequestValidator.validate_json(invalid_json)
    end

    test "returns error for missing required fields" do
      json =
        JSON.encode!(%{
          "custom_id" => "test"
          # Missing url, method, body, delivery_config
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
          "delivery_config" => %{
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
          "delivery_config" => %{
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
          "delivery_config" => %{
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
          "delivery_config" => %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert {:ok, validated} = RequestValidator.validate_json(json)
      # Verify keys are atoms (not strings)
      assert Map.has_key?(validated, :custom_id)
      assert Map.has_key?(validated, :url)
      assert Map.has_key?(validated, :body)
      assert Map.has_key?(validated, :delivery_config)
      # Verify nested maps also have atom keys
      assert Map.has_key?(validated.body, :model)
      assert Map.has_key?(validated.delivery_config, :type)
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
            "delivery_config" => %{
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
        "delivery_config" => %{
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

    test "handles validation errors with different error formats" do
      # Test with data that might produce different error formats
      data = %{
        "custom_id" => "test",
        "url" => "/v1/responses",
        "method" => "POST",
        # Should be a map
        "body" => "invalid"
      }

      result = RequestValidator.validate(data)
      assert {:error, {:validation_failed, errors}} = result
      assert is_list(errors)
      # Verify errors are formatted as strings
      assert Enum.all?(errors, &is_binary/1)
    end
  end

  describe "error formatting" do
    test "formats errors with path lists" do
      # This tests the format_errors function with path lists
      data = %{
        "custom_id" => "test",
        "url" => "/v1/responses",
        "method" => "POST",
        "body" => %{
          "model" => "gpt-4o-mini"
          # Missing input
        }
      }

      # This should trigger validation errors that get formatted
      result = RequestValidator.validate(data)
      assert {:error, {:validation_failed, errors}} = result
      assert is_list(errors)
    end

    test "handles non-map data in validate/1" do
      # Test that validate/1 only accepts maps (function clause error for non-maps)
      # This tests the guard clause behavior
      assert_raise FunctionClauseError, fn ->
        RequestValidator.validate("not a map")
      end
    end
  end
end
