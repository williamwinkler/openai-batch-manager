defmodule Batcher.Batching.Types.DeliveryTypeTest do
  use ExUnit.Case, async: true

  alias Batcher.Batching.Types.DeliveryType

  describe "DeliveryType" do
    test "has correct values" do
      assert :webhook in DeliveryType.values()
      assert :rabbitmq in DeliveryType.values()
      assert length(DeliveryType.values()) == 2
    end

    test "webhook has correct description" do
      assert DeliveryType.description(:webhook) == "Deliver via HTTP POST to a webhook URL"
    end

    test "rabbitmq has correct label" do
      assert DeliveryType.label(:rabbitmq) == "RabbitMQ"
    end

    test "rabbitmq has correct description" do
      assert DeliveryType.description(:rabbitmq) == "Deliver via RabbitMQ message queue"
    end

    test "can match values" do
      assert DeliveryType.match("webhook") == {:ok, :webhook}
      assert DeliveryType.match("rabbitmq") == {:ok, :rabbitmq}
      assert DeliveryType.match(:webhook) == {:ok, :webhook}
      assert DeliveryType.match(:rabbitmq) == {:ok, :rabbitmq}
    end

    test "match returns error for invalid value" do
      assert :error = DeliveryType.match("invalid")
      assert :error = DeliveryType.match(:invalid)
    end
  end
end
